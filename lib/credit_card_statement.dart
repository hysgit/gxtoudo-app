import 'dart:math' as math;

import 'domain.dart';
import 'ledger.dart';

final _creditCard = RegExp('信用卡|贷记卡');
final _repayment = RegExp(r'(信用卡|贷记卡).*还款|还(?:[\s\u4e00-\u9fff]+)?(?:信用卡|贷记卡)');

Map<String, List<Item>> creditCardTransactions(Iterable<Item> rows) {
  final cards = <String, List<Item>>{};
  for (final row in rows) {
    final party = text(row.data['party']).trim();
    final channel = text(row.data['channel']).trim();
    if (_creditCard.hasMatch(channel)) cards.putIfAbsent(channel, () => []);
    final card = _creditCard.hasMatch(party)
        ? party
        : ((party.isEmpty || party == '未注明') && _creditCard.hasMatch(channel))
        ? channel
        : null;
    if (card == null) continue;
    final transactions = cards.putIfAbsent(card, () => []);
    final type = text(row.data['type']);
    if ((type == 'expense' || type == 'income') &&
        !_repayment.hasMatch(row.name)) {
      transactions.add(row);
    }
  }
  return cards;
}

typedef StatementPeriod = ({DateTime start, DateTime endExclusive});

StatementPeriod creditCardPeriod(DateTime statementMonth, int statementDay) {
  if (statementDay < 1 || statementDay > 31) {
    throw RangeError.range(statementDay, 1, 31, 'statementDay');
  }
  DateTime cutoff(int offset) {
    final month = statementMonth.month + offset;
    final lastDay = DateTime.utc(statementMonth.year, month + 1, 0).day;
    return DateTime.utc(
      statementMonth.year,
      month,
      math.min(statementDay, lastDay),
    );
  }

  return (start: cutoff(-1), endExclusive: cutoff(0));
}

Map<String, ExactAmount> creditCardTotals(
  Iterable<Item> transactions,
  StatementPeriod period,
) {
  final start = billDate(period.start), end = billDate(period.endExclusive);
  final totals = <String, ExactAmount>{
    'CNY': ExactAmount(BigInt.zero, 0),
    'USD': ExactAmount(BigInt.zero, 0),
  };
  for (final row in transactions) {
    final date = text(row.data['date']);
    if (date.compareTo(start) < 0 || date.compareTo(end) >= 0) continue;
    final currency = billCurrency(row.data);
    final amount = ExactAmount.parse(text(row.data['amount']));
    final signed = row.data['type'] == 'income'
        ? ExactAmount(-amount.units, amount.scale)
        : amount;
    totals.update(currency, (value) => value + signed, ifAbsent: () => signed);
  }
  return totals;
}
