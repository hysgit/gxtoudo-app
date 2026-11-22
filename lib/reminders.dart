import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'domain.dart';
import 'schedule.dart';
import 'tasks.dart';

class TaskAlarm {
  TaskAlarm(this.task, this.occurrence, this.at, this.title);

  factory TaskAlarm.fromJson(Map<dynamic, dynamic> value) => TaskAlarm(
    text(value['task']),
    integer(value['occurrence']),
    integer(value['at']),
    text(value['title']),
  );

  final String task, title;
  final int occurrence, at;
  String get id => jsonEncode([task, occurrence, at]);
  Fields toJson() => {
    'id': id,
    'task': task,
    'occurrence': occurrence,
    'at': at,
    'title': title,
  };
}

int alarmTime(Task task, int occurrence, int lead) {
  if (lead > 864000) return occurrence + lead - task.start;
  final date = localTime(occurrence);
  if (lead == 0 && task.allDay) {
    return seconds(DateTime(date.year, date.month, date.day, 9));
  }
  return occurrence - lead;
}

List<TaskAlarm> alarmPlan(
  TodoController controller,
  List<TaskAlarm> existing,
  DateTime now, {
  int limit = 60,
  bool notifications = false,
}) {
  final who = controller.identity;
  final tasks = <String, Task>{
    for (final space in controller.spaces)
      for (final task in taskList(controller.data, who, space.id))
        if (task.alert != null &&
            task.start > 0 &&
            reminderMode(task.alert) !=
                (notifications ? 'alarm' : 'notification'))
          jsonEncode([who.scope, task.team, task.uid]): task,
  };
  final planned = <String, TaskAlarm>{};
  final current = seconds(now);
  // Preserve native snoozes and active alarms without resetting their next ring.
  for (final alarm in existing) {
    final task = tasks[alarm.task];
    if (task == null) continue;
    final lead = integer(task.alert!.data['alert_time'], -1);
    final occurrence = task.repeat == null
        ? task.start
        : task.on(dayOnly(localTime(alarm.occurrence)));
    if (lead < 0 ||
        occurrence != alarm.occurrence ||
        alarmTime(task, occurrence, lead) != alarm.at ||
        task.done(who.user, occurrence)) {
      continue;
    }
    final retained = TaskAlarm(alarm.task, occurrence, alarm.at, task.name);
    planned[retained.id] = retained;
  }
  for (final entry in tasks.entries) {
    final task = entry.value;
    final lead = integer(task.alert!.data['alert_time'], -1);
    if (lead < 0) continue;
    void add(int occurrence) {
      if (occurrence <= 0 || task.done(who.user, occurrence)) return;
      final at = alarmTime(task, occurrence, lead);
      if (at <= current) return;
      final alarm = TaskAlarm(entry.key, occurrence, at, task.name);
      planned[alarm.id] = alarm;
    }

    if (task.repeat == null) {
      add(task.start);
    } else {
      final first = dayOnly(localTime(task.start));
      final today = dayOnly(now);
      final start = first.isAfter(today) ? first : today;
      for (var i = 0; i <= 31; i++) {
        add(task.on(addDays(start, i)));
      }
    }
  }
  final result = planned.values.toList()..sort((a, b) => a.at.compareTo(b.at));
  return result.take(limit).toList();
}

class TodoReminders {
  TodoReminders(this.controller);
  final TodoController controller;
  static const _channel = MethodChannel('net.icycloud.fdtodolist/alarms');
  Future<void> _queued = Future.value();
  Timer? _debounce;
  bool _started = false;

  Future<void> start() async {
    if (!Platform.isIOS && !Platform.isAndroid) return;
    await _channel.invokeMethod<void>('initialize');
    _started = true;
    controller.addListener(queue);
    queue();
  }

  Future<void> request(String mode) async {
    if (!_started) throw StateError('闹钟尚未初始化，请重新打开 App');
    final errors = <String>[];
    for (final method in [
      if (mode != 'alarm') 'authorizeNotifications',
      if (mode != 'notification') 'authorize',
    ]) {
      try {
        await _channel.invokeMethod<void>(method);
      } on PlatformException catch (error) {
        errors.add(error.message ?? '请检查系统提醒权限');
      }
    }
    try {
      _debounce?.cancel();
      _queued = _queued.catchError((Object _) {}).then((_) => _rebuild());
      await _queued;
    } on PlatformException catch (error) {
      errors.add(error.message ?? '请检查系统提醒权限');
    }
    if (errors.isNotEmpty) throw StateError(errors.join('；'));
  }

  void queue() {
    if (!_started) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      _queued = _queued.then((_) => _rebuild()).catchError((Object error) {
        debugPrint('Alarm reconciliation failed: $error');
      });
    });
  }

  Future<void> _rebuild() async {
    if (!controller.ready) return;
    final now = DateTime.now();
    PlatformException? notificationError;
    try {
      final queued =
          await _channel.invokeListMethod<dynamic>('notificationSnapshot') ??
          [];
      final pending = queued
          .whereType<Map<dynamic, dynamic>>()
          .map(TaskAlarm.fromJson)
          .toList();
      final notifications = alarmPlan(
        controller,
        pending,
        now,
        notifications: true,
      );
      await _channel.invokeMethod<void>(
        'synchronizeNotifications',
        notifications.map((alarm) => alarm.toJson()).toList(),
      );
    } on PlatformException catch (error) {
      notificationError = error;
    }
    final status = await _channel.invokeMapMethod<String, dynamic>('status');
    if (status?['authorized'] == true) {
      final values = await _channel.invokeListMethod<dynamic>('snapshot') ?? [];
      final existing = values
          .whereType<Map<dynamic, dynamic>>()
          .map(TaskAlarm.fromJson)
          .toList();
      final plan = alarmPlan(controller, existing, now);
      await _channel.invokeMethod<void>(
        'synchronize',
        plan.map((alarm) => alarm.toJson()).toList(),
      );
    }
    if (notificationError != null) throw notificationError;
  }
}
