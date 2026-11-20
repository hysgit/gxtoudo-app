import 'dart:math' as math;

import 'domain.dart';

const billTypes = {'expense': '支出', 'income': '收入', 'transfer': '内转'};
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
    final order = text(b.data['date']).compareTo(text(a.data['date']));
    return order == 0 ? b.edited.compareTo(a.edited) : order;
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
  BillTotals(Iterable<Item> rows) {
    for (final row in rows) {
      final amount = ExactAmount.parse(text(row.data['amount']));
      if (row.data['type'] == 'expense') {
        expense = expense + amount;
        final party = text(row.data['party']);
        parties[party] =
            (parties[party] ?? ExactAmount(BigInt.zero, 0)) + amount;
      } else if (row.data['type'] == 'income') {
        income = income + amount;
      }
    }
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
  data.save(who, team, Tables.bill, uid, {
    ...changes,
    'amount': ExactAmount.parse(text(changes['amount'])).toString(),
  });
  for (final attachment in attachments) {
    final id = text(attachment['uid']);
    final current = data.get(team, Tables.billAttachment, id);
    if (data.items[itemKey(team, Tables.billAttachment, id)]?.removed == true) {
      throw const FormatException('附件已删除，请重新打开账单');
    }
    final value = {...attachment, 'note_id': uid, 'parent_table': Tables.bill};
    if (current != null &&
        current.data['client_media_id'] == attachment['client_media_id'] &&
        text(current.data['media_id']).isNotEmpty) {
      for (final field in ['media_id', 'content_type', 'size', 'sha256']) {
        value[field] = current.data[field];
      }
    }
    data.save(who, team, Tables.billAttachment, id, value);
  }
  for (final id in removed) {
    final row = data.get(team, Tables.billAttachment, id);
    if (row?.data['note_id'] == uid) data.remove(row);
  }
  for (final entry in media.entries) {
    data.media[entry.key] = {...entry.value, ...?data.media[entry.key]};
  }
}
