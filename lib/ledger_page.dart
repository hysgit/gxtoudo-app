import 'package:material_ui/material_ui.dart';

import 'appearance.dart';
import 'controller.dart';
import 'domain.dart';
import 'ledger.dart';

class BillTile extends StatelessWidget {
  const BillTile(this.bill, {super.key, required this.onTap});
  final Item bill;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final kind = text(bill.data['type']);
    final amount = billAmountLabel(
      ExactAmount.parse(text(bill.data['amount'])).toString(),
      billCurrency(bill.data),
    );
    final date = '${text(bill.data['date'])}  ${billTypes[kind] ?? kind}';
    final money = Text(
      amount,
      style: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        color: kind == 'expense'
            ? const Color(0xffb2493a)
            : kind == 'income'
            ? const Color(0xff28754a)
            : ink,
      ),
    );
    return ListTile(
      dense: true,
      minTileHeight: 44,
      minVerticalPadding: 2,
      visualDensity: const VisualDensity(vertical: -4),
      contentPadding: const EdgeInsets.symmetric(horizontal: 2),
      title: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          amount.length > 18
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(date, style: const TextStyle(fontSize: 13)),
                    money,
                  ],
                )
              : Row(
                  children: [
                    Expanded(
                      child: Text(date, style: const TextStyle(fontSize: 13)),
                    ),
                    money,
                  ],
                ),
          const SizedBox(height: 2),
          Text(
            '${text(bill.data['channel'])} · ${text(bill.data['party'])} · ${bill.name}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, color: muted),
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

class LedgerPage extends StatefulWidget {
  const LedgerPage(
    this.controller,
    this.team, {
    super.key,
    required this.onEdit,
    this.now,
  });
  final TodoController controller;
  final int team;
  final ValueChanged<Item> onEdit;
  final DateTime? now;
  @override
  State<LedgerPage> createState() => _LedgerPageState();
}

class _LedgerPageState extends State<LedgerPage> {
  bool archive = false;
  String? selectedMonth;
  Widget summary(BillTotals totals, String currency) {
    const expenseColor = Color(0xffa74635);
    const incomeColor = Color(0xff1e6c53);
    final parties = {
      ...totals.expenseByParty.keys,
      ...totals.incomeByParty.keys,
    };

    Widget cell(
      String label, {
      Color color = ink,
      bool heading = false,
      bool numeric = false,
    }) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Text(
        label,
        textAlign: numeric ? TextAlign.end : TextAlign.start,
        style: TextStyle(
          fontSize: 13,
          fontWeight: heading ? FontWeight.w600 : FontWeight.w400,
          color: color,
          fontFeatures: numeric ? const [FontFeature.tabularFigures()] : null,
        ),
      ),
    );

    Widget amountCell(ExactAmount? amount, Color color) => cell(
      amount == null ? '—' : billAmountLabel(amount.toString(), currency),
      color: amount == null ? muted : color,
      numeric: true,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (label, value) in [
                ('总支出', totals.expense),
                ('总收入', totals.income),
              ])
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: SelectableText(
                      '$label ${billAmountLabel(value.toString(), currency)}',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (parties.isNotEmpty) ...[
            const SizedBox(height: 4),
            Table(
              columnWidths: const {0: FlexColumnWidth(1.15)},
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              border: const TableBorder(
                horizontalInside: BorderSide(color: line),
              ),
              children: [
                TableRow(
                  decoration: const BoxDecoration(color: paper),
                  children: [
                    cell('支出收入方', heading: true),
                    cell(
                      '支出汇总',
                      color: expenseColor,
                      heading: true,
                      numeric: true,
                    ),
                    cell(
                      '收入汇总',
                      color: incomeColor,
                      heading: true,
                      numeric: true,
                    ),
                  ],
                ),
                for (final party in parties)
                  TableRow(
                    children: [
                      cell(party.isEmpty ? '未填写' : party),
                      amountCell(totals.expenseByParty[party], expenseColor),
                      amountCell(totals.incomeByParty[party], incomeColor),
                    ],
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final now = widget.now ?? DateTime.now();
      final current = billMonth(now);
      final months = archivedBillMonths(
        widget.controller.data,
        widget.team,
        now,
      );
      final years = months
          .map((month) => month.substring(0, 4))
          .toSet()
          .toList();
      final month = archive ? selectedMonth : current;
      final rows = month == null
          ? <Item>[]
          : monthlyBills(widget.controller.data, widget.team, month);
      return PageContent(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
        children: [
          SegmentedButton<bool>(
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: false, label: Text('本月')),
              ButtonSegment(value: true, label: Text('已归档')),
            ],
            selected: {archive},
            onSelectionChanged: (values) => setState(() {
              archive = values.single;
              selectedMonth = null;
            }),
          ),
          if (month != null) ...[
            if (archive)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => selectedMonth = null),
                  icon: const Icon(Icons.chevron_left),
                  label: Text(
                    '${month.substring(0, 4)}年 ${int.parse(month.substring(5))}月',
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${now.year}年 ${now.month}月',
                  style: const TextStyle(fontSize: 16),
                ),
              ),
            for (final entry in BillTotals.byCurrency(rows).entries)
              summary(entry.value, entry.key),
            if (rows.isEmpty)
              const EmptyContent('这个月还没有账单', icon: Icons.receipt_long_outlined),
            for (final bill in rows)
              BillTile(bill, onTap: () => widget.onEdit(bill)),
          ] else ...[
            const SizedBox(height: 8),
            if (months.isEmpty)
              const EmptyContent('还没有往月账单', icon: Icons.archive_outlined),
            for (final year in years)
              ExpansionTile(
                key: ValueKey('ledger-year-$year'),
                initiallyExpanded: year == years.first,
                title: Text('$year 年'),
                children: [
                  for (final month in months.where(
                    (month) => month.startsWith('$year-'),
                  ))
                    ListTile(
                      key: ValueKey('ledger-month-$month'),
                      dense: true,
                      title: Text('${int.parse(month.substring(5))} 月'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => setState(() => selectedMonth = month),
                    ),
                ],
              ),
          ],
        ],
      );
    },
  );
}
