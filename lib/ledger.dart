import 'dart:math' as math;

import 'domain.dart';
import 'record_versions.dart';

const billTypes = {'expense': '支出', 'income': '收入', 'transfer': '内转'};
const defaultBillCurrency = 'CNY';
const billCurrencies = {
  defaultBillCurrency: '人民币',
  'USD': '美元',
  'HKD': '港币',
  'EUR': '欧元',
  'JPY': '日元',
  'GBP': '英镑',
  'SGD': '新加坡元',
  'AUD': '澳元',
  'CAD': '加元',
  'KRW': '韩元',
  'TWD': '新台币',
};

String billCurrency(Fields bill) => switch (text(bill['currency'])) {
  '' => defaultBillCurrency,
  final currency => currency,
};

String billAmountLabel(String amount, String currency) =>
    currency == defaultBillCurrency ? amount : '$currency $amount';

const _legacyTotalsField = 'legacy_include_in_totals';

bool billIncluded(Fields bill) =>
    integer(bill[_legacyTotalsField], integer(bill['include_in_totals'], 1)) !=
    0;
const paymentChannels = [
  '支付宝',
  '微信',
  '美团支付',
  '抖音支付',
  '银闪付',
  '工行卡',
  '建行卡',
  '工行信用卡',
  '建行信用卡',
  '农行信用卡',
  '招行卡',
  'GooglePay',
  'PayPal',
];
const paymentParties = [
  '支付宝余额',
  '微信余额',
  '工行卡',
  '建行卡',
  '工行信用卡',
  '建行信用卡',
  '农行信用卡',
  '招行卡',
];

/// Decimal arithmetic stays integral; neither storage nor totals pass through double.
class ExactAmount {
  const ExactAmount(this.units, this.scale);
  factory ExactAmount.parse(String input) {
    final value = input.trim();
    if (!RegExp(r'^\d{1,30}(\.\d{1,18})?$').hasMatch(value)) {
      throw const FormatException('请输入非负金额，最多保留 18 位小数');
    }
    final parts = value.split('.');
    return ExactAmount(
      BigInt.parse(parts.join()),
      parts.length == 1 ? 0 : parts[1].length,
    );
  }
  final BigInt units;
  final int scale;
  ExactAmount operator +(ExactAmount other) {
    final target = math.max(scale, other.scale);
    return ExactAmount(
      units * BigInt.from(10).pow(target - scale) +
          other.units * BigInt.from(10).pow(target - other.scale),
      target,
    );
  }

  @override
  String toString() {
    final target = math.max(2, scale);
    final digits = (units * BigInt.from(10).pow(target - scale))
        .toString()
        .padLeft(target + 1, '0');
    return '${digits.substring(0, digits.length - target)}.${digits.substring(digits.length - target)}';
  }
}

String billDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
String billMonth(DateTime date) => billDate(date).substring(0, 7);

final _zoneSuffix = RegExp(r'(?:[zZ]|[+-]\d{2}:?\d{2})$');

int _billCreatedAt(Item bill) {
  final value = text(bill.data['created_at']);
  final timestamp = _zoneSuffix.hasMatch(value) ? value : '${value}Z';
  return DateTime.tryParse(timestamp)?.microsecondsSinceEpoch ?? 0;
}

List<Item> monthlyBills(
  WorkspaceData data,
  int team,
  String month, {
  String query = '',
}) {
  final needle = query.trim().toLowerCase();
  final values = data
      .list(team, Tables.bill)
      .where(
        (row) =>
            text(row.data['date']).startsWith('$month-') &&
            '${row.name} ${text(row.data['channel'])} ${text(row.data['party'])} ${text(row.data['remark'])}'
                .toLowerCase()
                .contains(needle),
      )
      .toList();
  values.sort((a, b) {
    final dateOrder = text(b.data['date']).compareTo(text(a.data['date']));
    if (dateOrder != 0) return dateOrder;
    final createdOrder = _billCreatedAt(b).compareTo(_billCreatedAt(a));
    return createdOrder == 0 ? b.uid.compareTo(a.uid) : createdOrder;
  });
  return values;
}

List<String> archivedBillMonths(WorkspaceData data, int team, DateTime now) {
  final current = billMonth(now);
  final months = data
      .list(team, Tables.bill)
      .map((row) => text(row.data['date']))
      .where((date) => date.length == 10)
      .map((date) => date.substring(0, 7))
      .where((month) => month.compareTo(current) < 0)
      .toSet()
      .toList();
  months.sort((a, b) => b.compareTo(a));
  return months;
}

class BillTotals {
  BillTotals._();

  static Map<String, BillTotals> byCurrency(Iterable<Item> rows) {
    final totals = {defaultBillCurrency: BillTotals._()};
    for (final row in rows) {
      final type = row.data['type'];
      if (!billIncluded(row.data) || (type != 'expense' && type != 'income')) {
        continue;
      }
      final group = totals.putIfAbsent(billCurrency(row.data), BillTotals._);
      final amount = ExactAmount.parse(text(row.data['amount']));
      if (type == 'expense') {
        group.expense = group.expense + amount;
        final party = text(row.data['party']);
        group.parties[party] =
            (group.parties[party] ?? ExactAmount(BigInt.zero, 0)) + amount;
      } else {
        group.income = group.income + amount;
      }
    }
    return totals;
  }

  ExactAmount expense = ExactAmount(BigInt.zero, 0),
      income = ExactAmount(BigInt.zero, 0);
  final parties = <String, ExactAmount>{};
}

List<String> billChoices(WorkspaceData data, int team, String kind) => {
  ...(kind == 'channel' ? paymentChannels : paymentParties),
  ...data.items.values
      .where((row) => !row.removed && row.table == Tables.billOption)
      .where((row) => row.data['kind'] == kind)
      .map((row) => row.name),
  ...data.items.values
      .where((row) => !row.removed && row.table == Tables.bill)
      .map((row) => text(row.data[kind]))
      .where((name) => name.isNotEmpty),
}.toList();

void saveBill(
  WorkspaceData data,
  Identity who,
  int team,
  String uid,
  Fields changes,
  List<Fields> attachments,
  Map<String, Fields> media, {
  Set<String> removed = const {},
}) {
  final existing = data.get(team, Tables.bill, uid);
  if (existing != null) captureBill(data, who, existing, onlyIfMissing: true);
  data.save(who, team, Tables.bill, uid, {
    if (existing == null)
      'created_at': DateTime.now().toUtc().toIso8601String(),
    ...changes,
    if (changes.containsKey('include_in_totals') &&
        existing?.data.containsKey(_legacyTotalsField) == true)
      _legacyTotalsField: '',
    'amount': ExactAmount.parse(text(changes['amount'])).toString(),
  });
  saveRecordAttachments(
    data,
    who,
    team,
    Tables.billAttachment,
    uid,
    attachments,
    media,
    removed,
  );
  captureBill(data, who, data.get(team, Tables.bill, uid)!);
}

const billVersionFields = [
  'name',
  'date',
  'type',
  'amount',
  'currency',
  'channel',
  'party',
  'remark',
  'location',
  'latitude',
  'longitude',
  'include_in_totals',
];

void captureBill(
  WorkspaceData data,
  Identity who,
  Item bill, {
  bool onlyIfMissing = false,
  String action = '保存',
}) => captureVersion(
  data,
  who,
  bill.team,
  Tables.bill,
  bill.uid,
  {
    for (final key in billVersionFields)
      key: key == 'include_in_totals'
          ? (billIncluded(bill.data) ? 1 : 0)
          : key == 'currency'
          ? billCurrency(bill.data)
          : text(bill.data[key]),
    'attachments': attachmentIds(
      data,
      bill.team,
      Tables.billAttachment,
      bill.uid,
    ),
  },
  onlyIfMissing: onlyIfMissing,
  action: action,
);

void revertBill(WorkspaceData data, Identity who, Item row, Fields snapshot) {
  final current = data.get(row.team, Tables.bill, row.uid);
  if (current == null) throw const FormatException('账单已删除');
  ExactAmount.parse(text(snapshot['amount']));
  if (text(snapshot['name']).isEmpty ||
      !billTypes.containsKey(snapshot['type'])) {
    throw const FormatException('此账单版本不完整');
  }
  captureBill(data, who, current, onlyIfMissing: true);
  data.save(who, row.team, Tables.bill, row.uid, {
    for (final key in billVersionFields) key: snapshot[key],
    'currency': billCurrency(snapshot),
    if (current.data.containsKey(_legacyTotalsField)) _legacyTotalsField: '',
  });
  restoreAttachmentIds(
    data,
    who,
    row.team,
    Tables.billAttachment,
    row.uid,
    snapshot['attachments'] as List<Object?>,
  );
  captureBill(
    data,
    who,
    data.get(row.team, Tables.bill, row.uid)!,
    action: '还原版本',
  );
}
