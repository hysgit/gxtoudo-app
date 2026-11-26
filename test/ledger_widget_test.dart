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

  testWidgets('底部显示任务、时间轴、AI、记账和便签', (tester) async {
    await tester.binding.setSurfaceSize(const Size(393, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.padding = const FakeViewPadding(top: 62);
    addTearDown(tester.view.resetPadding);
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
      ['任务', '时间轴', 'AI', '记账', '便签'],
    );
    expect(find.text('全部'), findsOneWidget);
    expect(tester.getSize(find.byType(AppBar)).height, 118);
    await tester.tap(find.text('记账'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(AppBar)).height, 106);
    expect(find.text('本月'), findsOneWidget);
    expect(find.text('已归档'), findsOneWidget);
    expect(find.text('项目'), findsNothing);
    expect(find.byTooltip('新建账单'), findsOneWidget);
    await tester.tap(find.text('AI'));
    await tester.pumpAndSettle();
    expect(find.text('登录后使用 AI'), findsOneWidget);
  });
  testWidgets('本月和归档均按收支方逐行显示支出和收入汇总', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
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
      for (final date in ['2026-11-01', '2026-10-01']) {
        for (final (type, amount, party) in [
          ('expense', '2.00', '微信余额'),
          ('income', '3.00', '微信余额'),
          ('expense', '4.00', '支付宝余额'),
          ('income', '7.50', '工行卡'),
        ]) {
          saveBill(
            data,
            who,
            -1,
            '$date-$type-$party',
            {
              'name': '单独统计',
              'date': date,
              'type': type,
              'amount': amount,
              'channel': '微信',
              'party': party,
              'include_in_totals': 0,
            },
            [],
            {},
          );
        }
      }
      saveBill(
        data,
        who,
        -1,
        'usd',
        {
          'name': '美元账单',
          'date': '2026-10-02',
          'type': 'expense',
          'amount': '2.50',
          'currency': 'USD',
          'channel': '支付宝',
          'party': '工行信用卡',
          billPartyStatsField: 0,
        },
        [],
        {},
      );
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

    void expectPartyTable() {
      final table = find.byType(Table);
      Finder cell(String value) =>
          find.descendant(of: table, matching: find.text(value));

      expect(tester.widget<Table>(table).children, hasLength(4));
      final partyHeader = tester.getCenter(cell('支出收入方'));
      final expenseHeader = tester.getCenter(cell('支出汇总'));
      final incomeHeader = tester.getCenter(cell('收入汇总'));
      expect(expenseHeader.dx, greaterThan(partyHeader.dx));
      expect(incomeHeader.dx, greaterThan(expenseHeader.dx));
      final expenseStyle = tester.widget<Text>(cell('支出汇总')).style;
      final incomeStyle = tester.widget<Text>(cell('收入汇总')).style;
      expect(expenseStyle?.color, isNot(incomeStyle?.color));

      final party = tester.getCenter(cell('微信余额'));
      final expense = tester.getCenter(cell('2.10 元'));
      final income = tester.getCenter(cell('3.00 元'));
      expect(expense.dy, party.dy);
      expect(income.dy, party.dy);
      expect(expense.dx, expenseHeader.dx);
      expect(income.dx, incomeHeader.dx);
      final missing = tester.getCenter(cell('—').first);
      final otherMissing = tester.getCenter(cell('—').last);
      expect(
        [missing.dy, otherMissing.dy],
        unorderedEquals([
          tester.getCenter(cell('支付宝余额')).dy,
          tester.getCenter(cell('工行卡')).dy,
        ]),
      );
      expect(cell('—'), findsNWidgets(2));
    }

    expect(find.textContaining('账单 2026-11-01'), findsOneWidget);
    expect(find.text('总支出 0.10 元'), findsOneWidget);
    expect(find.text('总收入 0.00 元'), findsOneWidget);
    expectPartyTable();
    expect(find.text('0.10 元'), findsOneWidget);
    await tester.tap(find.text('已归档'));
    await tester.pumpAndSettle();
    expect(find.text('2026 年'), findsOneWidget);
    expect(find.text('2025 年'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ledger-month-2026-10')));
    await tester.pumpAndSettle();
    expect(find.textContaining('账单 2026-10-01'), findsOneWidget);
    expect(find.text('总支出 0.10 元'), findsOneWidget);
    expect(find.text('总收入 0.00 元'), findsOneWidget);
    expectPartyTable();
    expect(find.text('总支出 USD 2.50'), findsOneWidget);
    expect(find.text('工行信用卡'), findsNothing);
    expect(find.text('USD 2.50'), findsOneWidget);
    expect(find.textContaining('账单 2026-11-01'), findsNothing);
  });
  testWidgets('点汇总金额按收支方、类型和币种筛选，再点恢复全部', (tester) async {
    await tester.binding.setSurfaceSize(const Size(393, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = TodoController(MemoryRepository());
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.mutate((data, who) {
      for (final date in ['2026-11-01', '2026-10-01']) {
        for (final (name, type, party, currency, amount, inStats) in [
          ('已计入支出', 'expense', '微信余额', 'CNY', '8', 1),
          ('仅计分项', 'expense', '微信余额', 'CNY', '4', 1),
          ('不计分项', 'expense', '微信余额', 'CNY', '30', 0),
          ('已计入收入', 'income', '微信余额', 'CNY', '10', 1),
          ('另一收支方', 'expense', '工行卡', 'CNY', '6', 1),
          ('另一币种', 'expense', '微信余额', 'USD', '12', 1),
        ]) {
          saveBill(
            data,
            who,
            -1,
            '$date-$name',
            {
              'name': name,
              'date': date,
              'type': type,
              'party': party,
              'currency': currency,
              'amount': amount,
              'include_in_totals': name == '仅计分项' ? 0 : 1,
              billPartyStatsField: inStats,
            },
            [],
            {},
          );
        }
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

    Finder amount(String value) =>
        find.descendant(of: find.byType(Table), matching: find.text(value));
    Iterable<String> billNames() => tester
        .widgetList<BillTile>(find.byType(BillTile))
        .map((tile) => tile.bill.name);
    Future<void> tapAmount(String value) async {
      await tester.tap(amount(value));
      await tester.pumpAndSettle();
    }

    expect(billNames(), hasLength(6));
    await tapAmount('12.00 元');
    expect(billNames(), unorderedEquals(['已计入支出', '仅计分项']));
    expect(find.text('总支出 44.00 元'), findsOneWidget);
    expect(amount('USD 12.00'), findsOneWidget);
    await tapAmount('12.00 元');
    expect(billNames(), hasLength(6));
    await tapAmount('10.00 元');
    expect(billNames(), ['已计入收入']);
    await tapAmount('USD 12.00');
    expect(billNames(), ['另一币种']);
    await tester.tap(find.text('已归档'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ledger-month-2026-10')));
    await tester.pumpAndSettle();
    expect(billNames(), hasLength(6));
    await tapAmount('12.00 元');
    expect(billNames(), unorderedEquals(['已计入支出', '仅计分项']));
    await tapAmount('12.00 元');
    expect(billNames(), hasLength(6));
  });
  testWidgets('窄屏并排显示途径和收支方，微信自动选余额且可手动更改', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
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
    final channel = find.widgetWithText(PopupMenuButton<String>, '途径');
    final party = find.widgetWithText(PopupMenuButton<String>, '支出方');
    expect(tester.getCenter(channel).dy, tester.getCenter(party).dy);
    expect(tester.getCenter(channel).dx, lessThan(tester.getCenter(party).dx));

    await tester.tap(channel);
    await tester.pumpAndSettle();
    final wechat = find.widgetWithText(PopupMenuItem<String>, '微信');
    expect(tester.getSize(wechat).height, 40);
    await tester.tap(wechat);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: party, matching: find.text('微信余额')),
      findsOneWidget,
    );

    await tester.tap(party);
    await tester.pumpAndSettle();
    final bank = find.widgetWithText(PopupMenuItem<String>, '工行卡');
    expect(tester.getSize(bank).height, 40);
    await tester.tap(bank);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: party, matching: find.text('工行卡')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('窄屏账单默认人民币，选美元后精确金额和定位一同保存', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
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
    expect(find.text('人民币'), findsOneWidget);
    expect(
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, '计入支出统计'),
          )
          .value,
      isTrue,
    );
    await tester.tap(
      find.widgetWithText(DropdownButtonFormField<String>, '类型'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('收入'));
    await tester.pumpAndSettle();
    final partyStats = find.widgetWithText(CheckboxListTile, '计入收入统计');
    expect(tester.widget<CheckboxListTile>(partyStats).value, isTrue);
    await tester.tap(partyStats);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(partyStats).value, isFalse);
    await tester.tap(find.text('人民币'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('美元').last);
    await tester.pumpAndSettle();
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
    expect(row.data['currency'], 'USD');
    expect(row.data['location'], '测试地点');
    expect(row.data['latitude'], '30.1');
    expect(row.data['type'], 'income');
    expect(row.data['include_in_totals'], 1);
    expect(row.data[billPartyStatsField], 0);
    expect(row.pending, 1);
  });
}
