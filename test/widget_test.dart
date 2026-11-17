import 'package:flutter_test/flutter_test.dart';
import 'package:gxtodo/controller.dart';
import 'package:gxtodo/domain.dart';
import 'package:gxtodo/home.dart';
import 'package:material_ui/material_ui.dart';

import 'memory_repository.dart';

void main() {
  testWidgets('离线新建任务、标记完成、重启后仍能读取', (tester) async {
    final store = MemoryRepository();
    final controller = TodoController(store);
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(TodoApp(controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建任务'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '提交新版本');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('提交新版本'), findsOneWidget);
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('已完成'), findsOneWidget);
    final restarted = TodoController(store);
    addTearDown(restarted.dispose);
    await restarted.initialize();
    expect(restarted.data.list(-1, Tables.task).single.name, '提交新版本');
    expect(restarted.data.list(-1, Tables.check).single.data['status'], 1);
  });

  testWidgets('新建便签并通过搜索找到', (tester) async {
    final controller = TodoController(MemoryRepository());
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(TodoApp(controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('便签'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建便签'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '带雨伞');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '雨伞');
    await tester.pumpAndSettle();
    expect(find.text('带雨伞'), findsOneWidget);
  });
}
