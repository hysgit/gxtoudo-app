import 'package:material_ui/material_ui.dart';

import 'appearance.dart';
import 'controller.dart';
import 'credit_card_statement_view.dart';
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
    final dateAndFlags = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            date,
            style: const TextStyle(
              fontSize: 13,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(width: 4),
        _BillExclusionSlot(
          key: const ValueKey('bill-total-slot'),
          visible: !billIncluded(bill.data),
          color: const Color(0xffb2493a),
          label: '未计入总支出或总收入',
        ),
        _BillExclusionSlot(
          key: const ValueKey('bill-party-slot'),
          visible: !billIncludedInPartyStats(bill.data),
          color: const Color(0xff28754a),
          label: '未计入分项统计',
        ),
      ],
    );
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
                  children: [dateAndFlags, money],
                )
              : Row(
                  children: [
                    Expanded(child: dateAndFlags),
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

class _BillExclusionSlot extends StatelessWidget {
  const _BillExclusionSlot({
    super.key,
    required this.visible,
    required this.color,
    required this.label,
  });

  final bool visible;
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: MediaQuery.textScalerOf(context).scale(17),
    child: visible
        ? Semantics(
            label: label,
            excludeSemantics: true,
            child: Text(
              '☑',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: color),
            ),
          )
        : null,
  );
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

typedef _PartySelection = ({
  String month,
  String currency,
  String type,
  String party,
});

enum _LedgerSection { current, archived, statements }

class _LedgerPageState extends State<LedgerPage> {
  _LedgerSection section = _LedgerSection.current;
  String? selectedMonth;
  _PartySelection? selectedParty;

  Widget summary(BillTotals totals, String currency, String month) {
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

    Widget amountCell(String party, String type, ExactAmount? amount) {
      if (amount == null) return cell('—', color: muted, numeric: true);
      final selection = (
        month: month,
        currency: currency,
        type: type,
        party: party,
      );
      final selected = selectedParty == selection;
      final isExpense = type == 'expense';
      final partyLabel = party.isEmpty ? '未填写' : party;
      return Semantics(
        button: true,
        selected: selected,
        label: '$partyLabel${billTypes[type]}汇总',
        child: Material(
          color: selected
              ? (isExpense ? const Color(0xfffbe9e4) : const Color(0xffe4f3ea))
              : Colors.transparent,
          child: InkWell(
            onTap: () =>
                setState(() => selectedParty = selected ? null : selection),
            child: cell(
              billAmountLabel(amount.toString(), currency),
              color: isExpense ? expenseColor : incomeColor,
              heading: selected,
              numeric: true,
            ),
          ),
        ),
      );
    }

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
                      amountCell(
                        party,
                        'expense',
                        totals.expenseByParty[party],
                      ),
                      amountCell(party, 'income', totals.incomeByParty[party]),
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
      final archive = section == _LedgerSection.archived;
      final statements = section == _LedgerSection.statements;
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
      final month = statements
          ? null
          : archive
          ? selectedMonth
          : current;
      final rows = month == null
          ? <Item>[]
          : monthlyBills(widget.controller.data, widget.team, month);
      final selection = selectedParty;
      final matchingRows = selection == null || selection.month != month
          ? rows
          : rows
                .where(
                  (bill) =>
                      bill.data['type'] == selection.type &&
                      text(bill.data['party']) == selection.party &&
                      billCurrency(bill.data) == selection.currency &&
                      billIncludedInPartyStats(bill.data),
                )
                .toList();
      return PageContent(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
        children: [
          SegmentedButton<_LedgerSection>(
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: _LedgerSection.current, label: Text('本月')),
              ButtonSegment(value: _LedgerSection.archived, label: Text('已归档')),
              ButtonSegment(
                value: _LedgerSection.statements,
                label: Text('账单'),
              ),
            ],
            selected: {section},
            onSelectionChanged: (values) => setState(() {
              section = values.single;
              selectedMonth = null;
              selectedParty = null;
            }),
          ),
          if (statements)
            CreditCardStatementView(
              key: ValueKey((widget.controller.identity.scope, widget.team)),
              repository: widget.controller.repository,
              scope: widget.controller.identity.scope,
              now: now,
              bills: widget.controller.data.list(widget.team, Tables.bill),
            )
          else if (month != null) ...[
            if (archive)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() {
                    selectedMonth = null;
                    selectedParty = null;
                  }),
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
              summary(entry.value, entry.key, month),
            if (rows.isEmpty)
              const EmptyContent('这个月还没有账单', icon: Icons.receipt_long_outlined),
            if (rows.isNotEmpty && matchingRows.isEmpty)
              TextButton(
                onPressed: () => setState(() => selectedParty = null),
                child: const Text('没有符合筛选的账单，显示全部'),
              ),
            for (final bill in matchingRows)
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
