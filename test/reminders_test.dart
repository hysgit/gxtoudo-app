import 'package:flutter_test/flutter_test.dart';
import 'package:gxtodo/controller.dart';
import 'package:gxtodo/domain.dart';
import 'package:gxtodo/reminders.dart';
import 'package:gxtodo/schedule.dart';
import 'package:gxtodo/tasks.dart';

import 'memory_repository.dart';

void main() {
  late TodoController controller;
  final now = DateTime(2026, 11, 18, 9);

  setUp(() async {
    controller = TodoController(MemoryRepository());
    await controller.initialize();
  });
  tearDown(() => controller.dispose());

  Task add({int repeat = 0, int lead = 0, bool allDay = false}) {
    final start = seconds(DateTime(2026, 11, 18, 10));
    saveTask(
      controller.data,
      controller.identity,
      -1,
      null,
      TaskChanges(
        name: '闹钟测试',
        rank: 1,
        project: '',
        place: '',
        start: start,
        end: start + 3600,
        allDay: allDay,
        repeat: repeat,
        repeatEnd: 0,
        alert: lead,
        remark: '',
        review: '',
        tags: [],
        children: [],
      ),
    );
    return taskList(controller.data, controller.identity, -1).single;
  }

  test('保存其他数据不会改变已安排闹钟的标识', () {
    add();
    final first = alarmPlan(controller, [], now).single;
    controller.data.save(controller.identity, -1, Tables.note, 'n', {
      'name': '便签',
    });
    expect(alarmPlan(controller, [first], now).single.id, first.id);
  });

  test('已经到点的原生闹钟在重新调度时保留，供重响或稍后提醒使用', () {
    add();
    final first = alarmPlan(controller, [], now).single;
    final later = DateTime(2026, 11, 19, 12);
    expect(alarmPlan(controller, [], later), isEmpty);
    expect(alarmPlan(controller, [first], later).single.id, first.id);
  });

  test('完成或删除任务会撤销正在响铃的对应闹钟', () {
    final task = add();
    final first = alarmPlan(controller, [], now).single;
    toggleTask(controller.data, controller.identity, -1, task.uid, task.start);
    expect(alarmPlan(controller, [first], now), isEmpty);
    deleteTask(controller.data, -1, task.uid);
    expect(alarmPlan(controller, [first], now), isEmpty);
  });

  test('修改提醒时间后旧闹钟失效，使用新提醒时间', () {
    final task = add();
    final old = alarmPlan(controller, [], now).single;
    controller.data.save(
      controller.identity,
      -1,
      Tables.alert,
      task.alert!.uid,
      {...task.alert!.data, 'alert_time': 600},
    );
    final updated = alarmPlan(controller, [old], now).single;
    expect(updated.id, isNot(old.id));
    expect(updated.at, task.start - 600);
  });

  test('重复日程只撤销已经完成的那一次闹钟', () {
    final task = add(repeat: 1);
    final plan = alarmPlan(controller, [], now);
    expect(plan.length, 32);
    toggleTask(controller.data, controller.identity, -1, task.uid, task.start);
    final next = alarmPlan(controller, plan, now);
    expect(next.length, 31);
    expect(next.every((alarm) => alarm.occurrence != task.start), isTrue);
  });

  test('调度容量保留正在重响的旧闹钟并优先安排最近的日程', () {
    add(repeat: 1);
    final plan = alarmPlan(controller, [], now, limit: 2);
    expect(plan.length, 2);
    final later = alarmPlan(
      controller,
      plan,
      DateTime(2026, 11, 20, 12),
      limit: 2,
    );
    expect(later.map((alarm) => alarm.id), plan.map((alarm) => alarm.id));
  });
}
