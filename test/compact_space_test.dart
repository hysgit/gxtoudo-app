import 'package:flutter_test/flutter_test.dart';
import 'package:gxtodo/api.dart';
import 'package:gxtodo/controller.dart';
import 'package:gxtodo/domain.dart';
import 'package:gxtodo/home.dart';
import 'package:material_ui/material_ui.dart';

import 'memory_repository.dart';

void main() {
  late TodoController controller;
  setUp(() async {
    controller = TodoController(MemoryRepository(), automatic: false);
    await controller.initialize();
    controller.account = const Account(
      server: 'https://example.invalid',
      user: 1,
      login: 1,
      personal: 10,
      token: 'test',
      email: 'test@example.invalid',
      nickname: 'test',
    );
    controller.data = WorkspaceData(
      spaces: const [
        Space(10, '个人空间', 1, 1),
        Space(20, '团队甲', 11, 1),
        Space(30, '团队乙', 11, 1),
      ],
    );
    controller.team = 10;
    for (var i = 0; i < 24; i++) {
      controller.data.save(controller.identity, 10, Tables.task, 'task-$i', {
        'name': '任务 $i',
      });
    }
  });
  tearDown(() => controller.dispose());

  Future<void> open(WidgetTester tester, {double scale = 1}) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: TodoApp(controller),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('任务'));
    await tester.pumpAndSettle();
  }

  testWidgets('左右边缘按指定方向切空间并循环，切换时保留任务页', (tester) async {
    await open(tester);
    await tester.dragFrom(const Offset(2, 350), const Offset(150, 0));
    await tester.pumpAndSettle();
    expect(controller.team, 20);
    expect(find.text('团队甲'), findsOneWidget);
    expect(find.text('没有符合条件的任务'), findsOneWidget);
    await tester.dragFrom(const Offset(373, 350), const Offset(-150, 0));
    await tester.pumpAndSettle();
    expect(controller.team, 10);
    await tester.dragFrom(const Offset(373, 350), const Offset(-150, 0));
    await tester.pumpAndSettle();
    expect(controller.team, 30);
    await tester.dragFrom(const Offset(2, 350), const Offset(150, 0));
    await tester.pumpAndSettle();
    expect(controller.team, 10);
  });

  testWidgets('中间横滑、边缘短滑和外滑不切空间，边缘上下滑仍能滚动', (tester) async {
    await open(tester);
    await tester.dragFrom(const Offset(170, 350), const Offset(140, 0));
    await tester.pumpAndSettle();
    expect(controller.team, 10);
    await tester.dragFrom(const Offset(2, 350), const Offset(15, 0));
    await tester.pumpAndSettle();
    expect(controller.team, 10);
    await tester.dragFrom(const Offset(373, 350), const Offset(100, 0));
    await tester.pumpAndSettle();
    expect(controller.team, 10);
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    final before = scroll.position.pixels;
    await tester.dragFrom(const Offset(3, 500), const Offset(0, -220));
    await tester.pumpAndSettle();
    expect(controller.team, 10);
    expect(scroll.position.pixels, greaterThan(before));
  });

  testWidgets('平铺行高紧凑、无任务卡片外框，复选框仍可点击', (tester) async {
    await open(tester);
    expect(find.byType(Card), findsNothing);
    final first = find.byKey(const ValueKey('task-row-task-0'));
    expect(tester.getSize(first).height, lessThanOrEqualTo(56));
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Container &&
            widget.constraints?.maxWidth == 2 &&
            widget.constraints?.maxHeight == 20,
      ),
      findsNothing,
    );
    expect(
      tester.getSize(find.byType(Checkbox).first).height,
      greaterThanOrEqualTo(44),
    );
    expect(find.byTooltip('新建任务'), findsOneWidget);
    final scaffold = tester.state<ScaffoldState>(find.byType(Scaffold));
    scaffold.openDrawer();
    await tester.pumpAndSettle();
    expect(scaffold.isDrawerOpen, true);
    expect(find.text('我的空间'), findsOneWidget);
  });
}
