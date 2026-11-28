import 'dart:math' as math;

import 'domain.dart';
import 'ledger.dart';

final _creditCard = RegExp('信用卡|贷记卡');
final _repaymentAfter = RegExp(
  r'^([^，,：:]+?(?:信用卡|贷记卡))\s*(?:人民币|美元)?\s*还款(?:$|[\s（(，,：:])',
);
final _repaymentBefore = RegExp(
  r'^还(?:款(?:给|至|到)?)?\s*([^，,：:]+?(?:信用卡|贷记卡))(?:$|[\s（(，,：:])',
);

enum CardDirection {
  outgoing('出账'),
  incoming('入账');

  const CardDirection(this.label);
  final String label;
}

typedef CardMovement = ({String card, CardDirection direction, bool included});
typedef CardEntry = ({Item bill, CardDirection direction, bool included});

CardMovement? creditCardMovement(Fields data) {
  final type = text(data['type']);
  final party = text(data['party']).trim();
  final channel = text(data['channel']).trim();
  final actualCard = _creditCard.hasMatch(party)
      ? party
      : ((party.isEmpty || party == '未注明') && _creditCard.hasMatch(channel))
      ? channel
      : null;
  final name = text(data['name']).trim();
  final repaymentCard =
      (_repaymentAfter.firstMatch(name) ?? _repaymentBefore.firstMatch(name))
          ?.group(1);
  final inferredRepayment =
      repaymentCard != null && (type == 'expense' || type == 'transfer');
  final card = inferredRepayment ? repaymentCard : actualCard;
  if (card == null ||
      (!inferredRepayment && type != 'income' && type != 'expense')) {
    return null;
  }
  return (
    card: card,
    direction: inferredRepayment || type == 'income'
        ? CardDirection.incoming
        : CardDirection.outgoing,
    included:
        integer(data[billCardStatementField], inferredRepayment ? 0 : 1) != 0,
  );
}

String _cardName(String card) => card.replaceFirstMapped(
  RegExp(r'^(工商银行|工行银行|工商|建设银行|建设|农业银行|农业|招商银行|招商)(?=信用卡|贷记卡)'),
  (match) => switch (match[1]) {
    '工商银行' || '工行银行' || '工商' => '工行',
    '建设银行' || '建设' => '建行',
    '农业银行' || '农业' => '农行',
    _ => '招行',
  },
);

Map<String, List<CardEntry>> creditCardTransactions(Iterable<Item> rows) {
  final cards = <String, List<CardEntry>>{
    for (final row in rows)
      for (final field in ['party', 'channel'])
        if (text(row.data[field]).trim() case final name
            when _creditCard.hasMatch(name))
          name: [],
  };
  for (final bill in rows) {
    final movement = creditCardMovement(bill.data);
    if (movement == null) continue;
    final card = movement.card;
    final name = cards.containsKey(card)
        ? card
        : cards.keys
                  .where((known) => _cardName(known) == _cardName(card))
                  .firstOrNull ??
              _cardName(card);
    cards.putIfAbsent(name, () => []).add((
      bill: bill,
      direction: movement.direction,
      included: movement.included,
    ));
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

class CardStatementAmounts {
  const CardStatementAmounts(this.entries);

  final List<CardEntry> entries;

  Iterable<CardEntry> forDirection(CardDirection direction) =>
      entries.where((entry) => entry.direction == direction);

  ExactAmount total(CardDirection direction) =>
      forDirection(direction)
          .where((entry) => entry.included)
          .fold(
            ExactAmount(BigInt.zero, 0),
            (sum, entry) =>
                sum + ExactAmount.parse(text(entry.bill.data['amount'])),
          );

  ({ExactAmount outgoing, ExactAmount incoming, ExactAmount net}) get totals {
    final outgoing = total(CardDirection.outgoing);
    final incoming = total(CardDirection.incoming);
    return (
      outgoing: outgoing,
      incoming: incoming,
      net: outgoing + ExactAmount(-incoming.units, incoming.scale),
    );
  }
}

Map<String, CardStatementAmounts> creditCardAmounts(
  Iterable<CardEntry> transactions,
  StatementPeriod period,
) {
  final start = billDate(period.start), end = billDate(period.endExclusive);
  final byCurrency = <String, List<CardEntry>>{'CNY': [], 'USD': []};
  for (final entry in transactions) {
    final row = entry.bill.data;
    final date = text(row['date']);
    if (date.compareTo(start) < 0 || date.compareTo(end) >= 0) continue;
    byCurrency.putIfAbsent(billCurrency(row), () => []).add(entry);
  }
  return byCurrency.map(
    (currency, entries) => MapEntry(currency, CardStatementAmounts(entries)),
  );
}
