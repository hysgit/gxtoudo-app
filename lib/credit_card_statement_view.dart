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
  });

  final LocalRepository repository;
  final String scope;
  final DateTime now;
  final Iterable<Item> bills;

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

  Widget _card(String card, List<Item> transactions) => FutureBuilder<int?>(
    key: ValueKey(card),
    future: _days.putIfAbsent(card, () => _dayOf(card)),
    builder: (context, snapshot) {
      final day = snapshot.data;
      final period = day == null ? null : creditCardPeriod(month, day);
      final totals = period == null
          ? null
          : creditCardTotals(transactions, period);
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
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final currency in ['CNY', 'USD'])
                        Expanded(
                          child: _AmountLabel(currency, totals[currency]!),
                        ),
                    ],
                  ),
                  for (final entry in totals.entries)
                    if (entry.key != 'CNY' && entry.key != 'USD')
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: _AmountLabel(entry.key, entry.value),
                      ),
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
  const _AmountLabel(this.currency, this.amount);

  final String currency;
  final ExactAmount amount;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        billCurrencies[currency] ?? currency,
        style: const TextStyle(fontSize: 12, color: muted),
      ),
      SelectableText(
        billAmountLabel(amount.toString(), currency),
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    ],
  );
}
