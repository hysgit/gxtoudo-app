import 'package:flutter_test/flutter_test.dart';
import 'package:gxtodo/appearance.dart';
import 'package:gxtodo/bill_editor.dart';
import 'package:gxtodo/bill_location.dart';
import 'package:gxtodo/controller.dart';
import 'package:gxtodo/domain.dart';
import 'package:gxtodo/home.dart';
import 'package:gxtodo/ledger.dart';
import 'package:gxtodo/ledger_page.dart';
import 'package:material_ui/material_ui.dart';

import 'memory_repository.dart';

void main() {
  testWidgets('新增途径立即保存并可在下一次创建和其他空间直接选择', (tester) async {
    final controller = TodoController(MemoryRepository());
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: todoTheme(),
        home: BillEditor(
          controller,
          -1,
          locationLoader: () async => const BillLocation('测试地点', '30', '120'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('新增途径'));
    await tester.tap(find.byTooltip('新增途径'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '名称'), '测试支付方式');
    await tester.tap(find.text('添加'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    final restored = await controller.repository.read(Identity.guest.scope);
    expect(billChoices(restored, 999, 'channel'), contains('测试支付方式'));
    expect(restored.list(-1, Tables.billOption).single.name, '测试支付方式');
  });

  testWidgets('底部顺序为任务、时间轴、记账、便签，移除项目入口', (tester) async {
    final controller = TodoController(MemoryRepository());
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(TodoApp(controller));
    await tester.pumpAndSettle();
    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(
      bar.destinations.whereType<NavigationDestination>().map(
        (item) => item.label,
      ),
      ['任务', '时间轴', '记账', '便签'],
    );
    expect(find.text('全部'), findsOneWidget);
    await tester.tap(find.text('记账'));
    await tester.pumpAndSettle();
    expect(find.text('本月'), findsOneWidget);
    expect(find.text('已归档'), findsOneWidget);
    expect(find.text('项目'), findsNothing);
    expect(find.byTooltip('新建账单'), findsOneWidget);
  });
  testWidgets('归档按年、月逐级展开，选择后显示该月账单和汇总', (tester) async {
    final controller = TodoController(MemoryRepository());
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.mutate((data, who) {
      for (final date in ['2026-11-01', '2026-10-01', '2025-12-02']) {
        saveBill(
          data,
          who,
          -1,
          date,
          {
            'name': '账单 $date',
            'date': date,
            'type': 'expense',
            'amount': '0.10',
            'channel': '微信',
            'party': '微信余额',
          },
          [],
          {},
        );
      }
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: todoTheme(),
        home: Scaffold(
          body: LedgerPage(
            controller,
            -1,
            onEdit: (_) {},
            now: DateTime(2026, 11, 20),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('账单 2026-11-01'), findsOneWidget);
    await tester.tap(find.text('已归档'));
    await tester.pumpAndSettle();
    expect(find.text('2026 年'), findsOneWidget);
    expect(find.text('2025 年'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ledger-month-2026-10')));
    await tester.pumpAndSettle();
    expect(find.textContaining('账单 2026-10-01'), findsOneWidget);
    expect(find.text('总支出 0.10'), findsOneWidget);
    expect(find.text('总收入 0.00'), findsOneWidget);
    expect(find.textContaining('账单 2026-11-01'), findsNothing);
  });
  testWidgets('账单默认今天，精确金额和定位结果先保存到本机', (tester) async {
    final controller = TodoController(MemoryRepository());
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: todoTheme(),
        home: BillEditor(
          controller,
          -1,
          locationLoader: () async =>
              const BillLocation('测试地点', '30.1', '120.2'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(billDate(DateTime.now())), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, '金额'),
      '9007199254740993.01',
    );
    await tester.ensureVisible(find.widgetWithText(TextFormField, '事项'));
    await tester.enterText(find.widgetWithText(TextFormField, '事项'), '精确金额测试');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final row = controller.data.list(-1, Tables.bill).single;
    expect(row.data['amount'], '9007199254740993.01');
    expect(row.data['location'], '测试地点');
    expect(row.data['latitude'], '30.1');
    expect(row.pending, 1);
  });
}
