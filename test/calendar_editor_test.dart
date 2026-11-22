import 'package:flutter_test/flutter_test.dart';
import 'package:gxtodo/appearance.dart';
import 'package:gxtodo/controller.dart';
import 'package:gxtodo/home.dart';
import 'package:gxtodo/schedule.dart';
import 'package:gxtodo/task_editor.dart';
import 'package:gxtodo/tasks.dart';
import 'package:material_ui/material_ui.dart';

import 'memory_repository.dart';

Finder days() => find.byWidgetPredicate(
  (widget) =>
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith('calendar-day-'),
);
Finder day(DateTime value) => find.byKey(
  ValueKey('calendar-day-${value.toIso8601String().substring(0, 10)}'),
);

TaskChanges taskValues(DateTime start, {bool allDay = false, int alert = 0}) =>
    TaskChanges(
      name: '日历任务',
      rank: 1,
      project: '',
      place: '',
      start: seconds(start),
      end: seconds(start) + 3600,
      allDay: allDay,
      repeat: 0,
      repeatEnd: 0,
      alert: alert,
      remark: '',
      review: '',
      tags: [],
      children: [],
    );

Future<void> chooseDate(WidgetTester tester, DateTime value) async {
  await tester.tap(find.byIcon(Icons.calendar_month_outlined));
  await tester.pumpAndSettle();
  final localizations = MaterialLocalizations.of(
    tester.element(find.byType(DatePickerDialog)),
  );
  await tester.tap(find.byTooltip(localizations.inputDateModeButtonLabel));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byType(TextFormField),
    localizations.formatCompactDate(value),
  );
  await tester.tap(find.text(localizations.okButtonLabel));
  await tester.pumpAndSettle();
}

void main() {
  late TodoController controller;
  setUp(() async {
    controller = TodoController(MemoryRepository());
    await controller.initialize();
  });
  tearDown(() => controller.dispose());

  void phone(WidgetTester tester, [Size size = const Size(375, 812)]) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('新建任务默认非全天并在开始时提醒，保存后保持该设置', (tester) async {
    phone(tester);
    String? permissionRequested;
    await tester.pumpWidget(
      MaterialApp(
        theme: todoTheme(),
        home: TaskEditor(
          controller: controller,
          team: -1,
          day: DateTime(2032, 1, 31),
          onReminder: (mode) async {
            permissionRequested = mode;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
    expect(find.text('开始时间'), findsOneWidget);
    expect(find.text('开始时'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).first, '默认提醒');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final task = taskList(controller.data, controller.identity, -1).single;
    expect(task.allDay, isFalse);
    expect(task.alert!.data['alert_time'], 0);
    expect(permissionRequested, 'both');
  });

  testWidgets('编辑已有任务保留全天及无提醒设置', (tester) async {
    phone(tester);
    await controller.mutate(
      (data, who) => saveTask(
        data,
        who,
        -1,
        null,
        taskValues(DateTime(2032, 1, 31), allDay: true, alert: -1),
      ),
    );
    final task = taskList(controller.data, controller.identity, -1).single;
    await tester.pumpWidget(
      MaterialApp(
        theme: todoTheme(),
        home: TaskEditor(controller: controller, team: -1, task: task),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    expect(find.text('开始时间'), findsNothing);
    expect(find.text('无提醒'), findsOneWidget);
  });

  testWidgets('日历区域下滑展开月历，上滑回到同一所选日期的周历', (tester) async {
    phone(tester);
    await tester.pumpWidget(TodoApp(controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('时间轴'));
    await tester.pumpAndSettle();
    final today = dayOnly(DateTime.now());
    expect(days(), findsNWidgets(7));
    await tester.drag(
      find.byKey(const ValueKey('timeline-calendar')),
      const Offset(0, 100),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('month-calendar')), findsOneWidget);
    expect(days().evaluate().length, greaterThanOrEqualTo(28));
    expect(tester.widget<Semantics>(day(today)).properties.selected, isTrue);
    await tester.drag(
      find.byKey(const ValueKey('timeline-calendar')),
      const Offset(0, -100),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('week-calendar')), findsOneWidget);
    expect(days(), findsNWidgets(7));
    expect(tester.widget<Semantics>(day(today)).properties.selected, isTrue);
  });

  testWidgets('月历按月切换，月末闰年正确，收起后回到所选周', (tester) async {
    phone(tester);
    await tester.pumpWidget(TodoApp(controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('时间轴'));
    await tester.pumpAndSettle();
    await chooseDate(tester, DateTime(2031, 12, 31));
    await tester.drag(
      find.byKey(const ValueKey('timeline-calendar')),
      const Offset(0, 100),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下一月'));
    await tester.pumpAndSettle();
    expect(find.text('2032年 1月'), findsOneWidget);
    expect(
      tester.widget<Semantics>(day(DateTime(2032, 1, 31))).properties.selected,
      isTrue,
    );
    await tester.tap(find.byTooltip('下一月'));
    await tester.pumpAndSettle();
    expect(find.text('2032年 2月'), findsOneWidget);
    expect(
      tester.widget<Semantics>(day(DateTime(2032, 2, 29))).properties.selected,
      isTrue,
    );
    await tester.drag(
      find.byKey(const ValueKey('timeline-calendar')),
      const Offset(0, -100),
    );
    await tester.pumpAndSettle();
    expect(days(), findsNWidgets(7));
    expect(
      tester.widget<Semantics>(day(DateTime(2032, 2, 29))).properties.selected,
      isTrue,
    );
    await tester.tap(find.byTooltip('下一周'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Semantics>(day(DateTime(2032, 3, 7))).properties.selected,
      isTrue,
    );
  });

  testWidgets('月历点选日期保持展开，任务标记和当天任务对应', (tester) async {
    phone(tester);
    await controller.mutate(
      (data, who) =>
          saveTask(data, who, -1, null, taskValues(DateTime(2032, 2, 8, 10))),
    );
    await tester.pumpWidget(TodoApp(controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('时间轴'));
    await tester.pumpAndSettle();
    await chooseDate(tester, DateTime(2032, 2, 9));
    await tester.drag(
      find.byKey(const ValueKey('timeline-calendar')),
      const Offset(0, 100),
    );
    await tester.pumpAndSettle();
    final dot = tester.widget<Container>(
      find.byKey(const ValueKey('calendar-dot-2032-02-08')),
    );
    expect((dot.decoration as BoxDecoration).color, blue);
    await tester.tap(day(DateTime(2032, 2, 8)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('month-calendar')), findsOneWidget);
    expect(
      tester.widget<Semantics>(day(DateTime(2032, 2, 8))).properties.selected,
      isTrue,
    );
    expect(find.text('日历任务'), findsOneWidget);
    expect(
      tester.getSize(day(DateTime(2032, 2, 8))).height,
      greaterThanOrEqualTo(48),
    );
  });

  testWidgets('滚动任务区域不会收起月历', (tester) async {
    phone(tester);
    final today = dayOnly(DateTime.now());
    await controller.mutate((data, who) {
      for (var i = 0; i < 20; i++) {
        saveTask(data, who, -1, null, taskValues(today));
      }
    });
    await tester.pumpWidget(TodoApp(controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('时间轴'));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('timeline-calendar')),
      const Offset(0, 100),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.text('日历任务').first, const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('month-calendar')), findsOneWidget);
    expect(
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .pixels,
      greaterThan(0),
    );
  });

  for (final size in [const Size(375, 812), const Size(812, 375)]) {
    testWidgets('月历适应 $size、大字体和减少动态效果', (tester) async {
      phone(tester, size);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await tester.pumpWidget(
        MaterialApp(
          theme: todoTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: Workbench(controller),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('时间轴'));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('timeline-calendar')),
        const Offset(0, 100),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('month-calendar')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
