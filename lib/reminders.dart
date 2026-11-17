import 'dart:async';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'controller.dart';
import 'domain.dart';
import 'schedule.dart';
import 'tasks.dart';

class TodoReminders {
  TodoReminders(this.controller);
  final TodoController controller;
  final _plugin = FlutterLocalNotificationsPlugin();
  Future<void> _queued = Future.value();
  Timer? _debounce;
  bool _started = false;

  Future<void> start() async {
    if (!Platform.isIOS && !Platform.isAndroid) return;
    tzdata.initializeTimeZones();
    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('ic_reminder'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
    );
    _started = true;
    controller.addListener(queue);
    queue();
  }

  Future<void> request() async {
    if (!_started) return;
    if (Platform.isAndroid) {
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    } else if (Platform.isIOS) {
      await _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, sound: true);
    }
    queue();
  }

  void queue() {
    if (!_started) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      _queued = _queued.then((_) => _rebuild()).onError((_, _) {});
    });
  }

  Future<void> _rebuild() async {
    if (!controller.ready) return;
    final now = seconds(DateTime.now());
    final today = dayOnly(DateTime.now());
    final upcoming = <(int, String)>[];
    final who = controller.identity;
    for (final space in controller.spaces) {
      for (final task in taskList(controller.data, who, space.id)) {
        if (task.alert == null || task.start <= 0) continue;
        final lead = integer(task.alert!.data['alert_time'], -1);
        if (lead < 0) continue;
        final firstDay = dayOnly(localTime(task.start));
        if (task.repeat == null) {
          final at = _time(task, task.start, lead, firstDay);
          if (at > now && !task.done(who.user, task.start)) {
            upcoming.add((at, task.name));
          }
          continue;
        }
        final start = firstDay.isAfter(today) ? firstDay : today;
        for (var i = 0; i <= 31; i++) {
          final day = addDays(start, i);
          final instance = task.on(day);
          if (instance <= 0 || task.done(who.user, instance)) continue;
          final at = _time(task, instance, lead, day);
          if (at > now) upcoming.add((at, task.name));
        }
      }
    }
    upcoming.sort((left, right) => left.$1.compareTo(right.$1));
    await _plugin.cancelAllPendingNotifications();
    for (final (index, alarm) in upcoming.take(60).indexed) {
      await _plugin.zonedSchedule(
        index + 1,
        '高效Todo提醒',
        alarm.$2,
        tz.TZDateTime.fromMillisecondsSinceEpoch(tz.UTC, alarm.$1 * 1000),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'task_reminders',
            '任务提醒',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    }
  }

  int _time(Task task, int occurrence, int lead, DateTime date) {
    if (lead > 864000) return occurrence + lead - task.start;
    if (lead == 0 && task.allDay) {
      return seconds(DateTime(date.year, date.month, date.day, 9));
    }
    return occurrence - lead;
  }
}
