import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gxtodo/domain.dart';
import 'package:gxtodo/ledger.dart';

Fields bill(
  String name,
  String date,
  String type,
  String amount, {
  String party = '工行卡',
}) => {
  'name': name,
  'date': date,
  'type': type,
  'amount': amount,
  'channel': '支付宝',
  'party': party,
};

void main() {
  test('金额、累计、超出浮点安全范围及18位小数精确保留', () {
    expect(
      (ExactAmount.parse('0.1') + ExactAmount.parse('0.2')).toString(),
      '0.30',
    );
    expect(
      (ExactAmount.parse('9007199254740993.01') + ExactAmount.parse('0.09'))
          .toString(),
      '9007199254740993.10',
    );
    expect(
      (ExactAmount.parse('0.000000000000000001') +
              ExactAmount.parse('0.000000000000000002'))
          .toString(),
      '0.000000000000000003',
    );
    expect(ExactAmount.parse('001.2300').toString(), '1.2300');
    expect(() => ExactAmount.parse('-1'), throwsFormatException);
    expect(() => ExactAmount.parse('1e3'), throwsFormatException);
  });
  test('每月汇总只计收支，内转不重复计入，按支出方汇总', () {
    final data = WorkspaceData();
    const who = Identity.guest;
    for (final value in [
      bill('甲', '2026-11-01', 'expense', '0.10'),
      bill('乙', '2026-11-02', 'expense', '0.20'),
      bill('丙', '2026-11-03', 'expense', '1.2300', party: '微信余额'),
      bill('收入', '2026-11-04', 'income', '9.99'),
      bill('内转', '2026-11-05', 'transfer', '10000'),
      bill('旧月', '2026-10-01', 'expense', '77'),
    ]) {
      saveBill(data, who, -1, newId(Tables.bill), value, [], {});
    }
    final totals = BillTotals(monthlyBills(data, -1, '2026-11'));
    expect(totals.expense.toString(), '1.5300');
    expect(totals.income.toString(), '9.99');
    expect(totals.parties['工行卡'].toString(), '0.30');
    expect(totals.parties['微信余额'].toString(), '1.2300');
    expect(archivedBillMonths(data, -1, DateTime(2026, 11, 20)), ['2026-10']);
  });
  test('动态选项跨空间复用，并随本机持久化和备份保留', () {
    final data = WorkspaceData();
    data.save(Identity.guest, -1, Tables.billOption, 'option', {
      'kind': 'channel',
      'name': '新支付方式',
    });
    final restored = WorkspaceData.fromJson(
      jsonDecode(jsonEncode(data.toJson())),
    );
    expect(billChoices(restored, 999, 'channel'), contains('新支付方式'));
    expect(billChoices(restored, 999, 'channel'), containsAll(paymentChannels));
    expect(billChoices(restored, 999, 'party'), containsAll(paymentParties));
    expect(restored.exportPersonal(Identity.guest)['items'], isNotEmpty);
  });
  test('保存账单保留金额字符串和已有上传回执，不误删并发新增附件', () {
    final data = WorkspaceData();
    const who = Identity.guest;
    final header = bill('账单', '2026-11-20', 'expense', '123456789.123456789');
    saveBill(data, who, -1, 'bill', header, [
      {
        'uid': 'attachment',
        'kind': 'file',
        'client_media_id': 'local',
        'media_id': '',
      },
    ], {});
    data.save(who, -1, Tables.billAttachment, 'attachment', {
      'media_id': 'remote',
      'size': 5,
      'sha256': 'abc',
      'content_type': 'application/octet-stream',
    });
    data.save(who, -1, Tables.billAttachment, 'concurrent', {
      'note_id': 'bill',
      'kind': 'image',
      'media_id': 'other',
    });
    saveBill(data, who, -1, 'bill', header, [
      {
        'uid': 'attachment',
        'kind': 'file',
        'client_media_id': 'local',
        'media_id': '',
      },
    ], {});
    expect(
      data.get(-1, Tables.bill, 'bill')!.data['amount'],
      '123456789.123456789',
    );
    expect(
      data.get(-1, Tables.billAttachment, 'attachment')!.data['media_id'],
      'remote',
    );
    expect(data.get(-1, Tables.billAttachment, 'concurrent'), isNotNull);
    saveBill(data, who, -1, 'bill', header, [], {}, removed: {'attachment'});
    expect(data.get(-1, Tables.billAttachment, 'attachment'), isNull);
    expect(data.get(-1, Tables.billAttachment, 'concurrent'), isNotNull);
  });
}
