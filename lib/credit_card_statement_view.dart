import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'appearance.dart';
import 'credit_card_statement.dart';
import 'domain.dart';
import 'ledger.dart';
import 'repository.dart';

class CreditCardStatementView extends StatefulWidget {
  const CreditCardStatementView({
    super.key,
    required this.repository,
    required this.scope,
    required this.now,
    required this.bills,
    required this.onEdit,
  });

  final LocalRepository repository;
  final String scope;
  final DateTime now;
  final Iterable<Item> bills;
  final ValueChanged<Item> onEdit;

  @override
  State<CreditCardStatementView> createState() =>
      _CreditCardStatementViewState();
}

class _CreditCardStatementViewState extends State<CreditCardStatementView> {
  late DateTime month = DateTime(widget.now.year, widget.now.month);
  final _days = <String, Future<int?>>{};
  final _saving = <String>{};

  String _settingKey(String card) =>
      'credit-card-statement-day:${jsonEncode([widget.scope, card])}';

  Future<int?> _dayOf(String card) async {
    final day = int.tryParse(
      await widget.repository.setting(_settingKey(card)) ?? '',
    );
    return day != null && day >= 1 && day <= 31 ? day : null;
  }

  Future<void> _setDay(String card, int? current) async {
    final settingsKey = _settingKey(card);
    int? selected = current;
    final day = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('$card账单日'),
          content: DropdownButtonFormField<int>(
            initialValue: current,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: '每月账单日',
              helperText: '当月天数不足时按月末计算',
            ),
            items: [
              for (var day = 1; day <= 31; day++)
                DropdownMenuItem(value: day, child: Text('$day 日')),
            ],
            onChanged: (value) => update(() => selected = value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: selected == null
                  ? null
                  : () => Navigator.pop(context, selected),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || day == null || !_saving.add(card)) return;
    setState(() {});
    try {
      await widget.repository.setSetting(settingsKey, '$day');
      if (mounted) _days[card] = Future.value(day);
    } catch (_) {
      if (mounted) message(context, '账单日保存失败，请重试');
    } finally {
      _saving.remove(card);
      if (mounted) setState(() {});
    }
  }

  void _moveMonth(int delta) {
    setState(() => month = DateTime(month.year, month.month + delta));
  }

  Future<void> _showDetails(
    String card,
    String currency,
    CardDirection direction,
    CardStatementAmounts amounts,
  ) async {
    final rows = amounts.forDirection(direction).toList()
      ..sort(
        (a, b) =>
            text(b.bill.data['date']).compareTo(text(a.bill.data['date'])),
      );
    final selected = await showModalBottomSheet<Item>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: 0.8,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              title: Text('$card · ${direction.label}明细'),
              subtitle: Text(
                billAmountLabel(amounts.total(direction).toString(), currency),
              ),
            ),
            Expanded(
              child: rows.isEmpty
                  ? const Center(child: Text('本期没有明细'))
                  : ListView.builder(
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.paddingOf(context).bottom,
                      ),
                      itemCount: rows.length,
                      itemBuilder: (context, index) {
                        final entry = rows[index];
                        final bill = entry.bill;
                        return ListTile(
                          dense: true,
                          title: Text(bill.name),
                          subtitle: Text(
                            [
                              text(bill.data['date']),
                              billAmountLabel(
                                ExactAmount.parse(text(bill.data['amount']))
                                    .toString(),
                                currency,
                              ),
                              if (!entry.included) '未计入',
                            ].join(' · '),
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.pop(context, bill),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
    if (mounted && selected != null) widget.onEdit(selected);
  }

  Widget _currency(String card, String currency, CardStatementAmounts amounts) {
    final (:incoming, :outgoing, :net) = amounts.totals;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text(
          billCurrencies[currency] ?? currency,
          style: const TextStyle(fontSize: 13, color: muted),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (direction, total) in [
              (CardDirection.outgoing, outgoing),
              (CardDirection.incoming, incoming),
            ])
              Expanded(
                child: TextButton(
                  style: TextButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  onPressed: () =>
                      _showDetails(card, currency, direction, amounts),
                  child: _AmountLabel(direction.label, currency, total),
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: _AmountLabel('净额', currency, net),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _card(
    String card,
    List<CardEntry> transactions,
  ) => FutureBuilder<int?>(
    key: ValueKey(card),
    future: _days.putIfAbsent(card, () => _dayOf(card)),
    builder: (context, snapshot) {
      final day = snapshot.data;
      final period = day == null ? null : creditCardPeriod(month, day);
      final totals = period == null
          ? null
          : creditCardAmounts(transactions, period);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: line),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.credit_card_outlined,
                      size: 18,
                      color: blue,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        card,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (!snapshot.hasError &&
                        snapshot.connectionState == ConnectionState.done)
                      TextButton(
                        onPressed: _saving.contains(card)
                            ? null
                            : () => _setDay(card, day),
                        child: Text(day == null ? '设置账单日' : '账单日 $day 日'),
                      ),
                  ],
                ),
                if (snapshot.hasError)
                  TextButton(
                    onPressed: () => setState(() => _days.remove(card)),
                    child: const Text('读取失败，重试'),
                  )
                else if (period != null && totals != null) ...[
                  Text(
                    '${billDate(period.start)} 至 '
                    '${billDate(period.endExclusive.subtract(const Duration(days: 1)))}',
                    style: const TextStyle(fontSize: 12, color: muted),
                  ),
                  for (final entry in totals.entries)
                    _currency(card, entry.key, entry.value),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final cards = creditCardTransactions(widget.bills);
    if (cards.isEmpty) {
      return const EmptyContent('还没有信用卡记录', icon: Icons.credit_card_outlined);
    }
    final names = cards.keys.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: '上个账单月',
              icon: const Icon(Icons.chevron_left),
              onPressed: () => _moveMonth(-1),
            ),
            Expanded(
              child: Text(
                '${month.year}年 ${month.month}月账单',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              tooltip: '下个账单月',
              icon: const Icon(Icons.chevron_right),
              onPressed: () => _moveMonth(1),
            ),
          ],
        ),
        for (final name in names) _card(name, cards[name]!),
      ],
    );
  }
}

class _AmountLabel extends StatelessWidget {
  const _AmountLabel(this.label, this.currency, this.amount);

  final String label;
  final String currency;
  final ExactAmount amount;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontSize: 12, color: muted)),
      Text(
        billAmountLabel(amount.toString(), currency),
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    ],
  );
}
