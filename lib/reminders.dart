import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'api.dart';
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
  Future<bool> _registering = Future.value(false);
  Timer? _debounce;
  bool _started = false;
  DateTime? _lastPushCheck;
  Account? _pushAccount, _signingOut;
  Fields? _registered;
  Completer<void>? _appleRegistration;

  Future<void> start() async {
    if (!Platform.isIOS && !Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pushTokenChanged') {
        _appleRegistration?.complete();
        _appleRegistration = null;
        _lastPushCheck = null;
        queue();
      } else if (call.method == 'pushRegistrationFailed') {
        _appleRegistration?.complete();
        _appleRegistration = null;
      }
    });
    await _channel.invokeMethod<void>('initialize');
    _started = true;
    controller.onLogout = _disablePush;
    controller.addListener(queue);
    queue();
  }

  Future<void> request(String mode) async {
    if (!_started) throw StateError('闹钟尚未初始化，请重新打开 App');
    final errors = <String>[];
    if (mode != 'alarm') {
      try {
        if (controller.account == null) {
          errors.add('登录并同步任务后才能收到远程推送');
        } else {
          await _channel.invokeMethod<void>('authorizeNotifications');
          if (!await _registerPush(
            force: _registered == null || _pushAccount != controller.account,
          )) {
            errors.add('远程推送暂未注册或服务端未配置');
          }
        }
      } on PlatformException catch (error) {
        errors.add(error.message ?? '请检查系统通知权限');
      } on ApiFailure catch (error) {
        errors.add(error.message);
      }
    }
    if (mode != 'notification') {
      try {
        await _channel.invokeMethod<void>('authorize');
      } on PlatformException catch (error) {
        errors.add(error.message ?? '请检查系统闹钟权限');
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
      unawaited(_registerPush().catchError((Object _) => false));
      _queued = _queued.then((_) => _rebuild()).catchError((Object error) {
        debugPrint('Alarm reconciliation failed: $error');
      });
    });
  }

  Future<void> _rebuild() async {
    if (!controller.ready) return;
    final now = DateTime.now();
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
  }

  Future<bool> _registerPush({bool force = false}) {
    final account = controller.account;
    if (account == null || account == _signingOut) return Future.value(false);
    final now = DateTime.now();
    if (!force &&
        _pushAccount == account &&
        _lastPushCheck != null &&
        now.difference(_lastPushCheck!) < const Duration(minutes: 2)) {
      return _registering;
    }
    final previous = _registering;
    _lastPushCheck = now;
    if (_pushAccount != account) _registered = null;
    _pushAccount = account;
    return _registering = previous.catchError((Object _) => false).then((
      _,
    ) async {
      if (controller.account != account || account == _signingOut) return false;
      if (force && Platform.isIOS) _appleRegistration ??= Completer<void>();
      var info = await _channel
          .invokeMapMethod<String, dynamic>('pushInfo')
          .timeout(const Duration(seconds: 8), onTimeout: () => null);
      if (info == null &&
          force &&
          Platform.isIOS &&
          _appleRegistration != null) {
        await _appleRegistration!.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () {},
        );
        info = await _channel.invokeMapMethod<String, dynamic>('pushInfo');
      }
      if (controller.account != account || account == _signingOut) return false;
      final api = TodoApi(account.server, account);
      if (info == null) return false;
      if (!force && mapEquals(info, _registered)) return true;
      final reply = await api.call('/push/device', method: 'PUT', values: info);
      if (reply['configured'] != true) return false;
      _registered = info;
      return true;
    });
  }

  Future<void> _disablePush(Account account) async {
    _signingOut = account;
    _registered = null;
    final api = TodoApi(account.server, account);
    try {
      await _registering
          .catchError((Object _) => false)
          .timeout(const Duration(seconds: 5));
    } on TimeoutException {
      // Native delivery is disabled even if the registration request outlives logout.
    }
    await Future.wait(
      [
        api.call('/push/device', method: 'DELETE').then<void>((_) {}),
        _channel.invokeMethod<void>('disablePush'),
      ].map(
        (operation) => operation
            .timeout(const Duration(seconds: 5))
            .catchError((Object _) {}),
      ),
    );
  }
}
