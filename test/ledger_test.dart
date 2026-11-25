import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gxtodo/domain.dart';
import 'package:gxtodo/ledger.dart';
import 'package:gxtodo/record_versions.dart';

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
  test('每月按币种汇总，勾选只影响顶部收支，内转不计入', () {
    final data = WorkspaceData();
    const who = Identity.guest;
    for (final value in [
      bill('甲', '2026-11-01', 'expense', '0.10'),
      bill('乙', '2026-11-02', 'expense', '0.20'),
      bill('丙', '2026-11-03', 'expense', '1.2300', party: '微信余额'),
      bill('收入', '2026-11-04', 'income', '9.99'),
      bill('内转', '2026-11-05', 'transfer', '10000'),
      {
        ...bill('订阅', '2026-11-04', 'expense', '19.99'),
        'currency': 'USD',
        'include_in_totals': 0,
        'legacy_include_in_totals': '1',
      },
      {...bill('退款', '2026-11-05', 'income', '1.00'), 'currency': 'USD'},
      {
        ...bill('不计入总支出', '2026-11-05', 'expense', '9'),
        'currency': 'USD',
        'include_in_totals': 0,
      },
      {
        ...bill('不计入总收入', '2026-11-06', 'income', '2.05'),
        'currency': 'USD',
        'include_in_totals': 0,
      },
      bill('旧月', '2026-10-01', 'expense', '77'),
    ]) {
      saveBill(data, who, -1, newId(Tables.bill), value, [], {});
    }
    final groups = BillTotals.byCurrency(monthlyBills(data, -1, '2026-11'));
    final totals = groups['CNY']!;
    expect(totals.expense.toString(), '1.5300');
    expect(totals.income.toString(), '9.99');
    expect(totals.expenseByParty['工行卡'].toString(), '0.30');
    expect(totals.expenseByParty['微信余额'].toString(), '1.2300');
    expect(totals.incomeByParty['工行卡'].toString(), '9.99');
    expect(groups['USD']!.expense.toString(), '19.99');
    expect(groups['USD']!.expenseByParty['工行卡'].toString(), '28.99');
    expect(groups['USD']!.income.toString(), '1.00');
    expect(groups['USD']!.incomeByParty['工行卡'].toString(), '3.05');
    expect(archivedBillMonths(data, -1, DateTime(2026, 11, 20)), ['2026-10']);
  });
  test('先按账单日期排序，再按创建时间排序，编辑旧账单无需移动', () {
    final data = WorkspaceData();
    const who = Identity.guest;
    for (final (uid, date, created) in [
      ('older', '2026-11-18', '2026-11-24 08:00:00'),
      ('newer', '2026-11-18', '2026-11-24T08:00:00.001Z'),
      ('later-date', '2026-11-19', '2026-11-24T15:00:00+08:00'),
      ('later-date-later-time', '2026-11-19', '2026-11-24 07:01:00'),
    ]) {
      saveBill(
        data,
        who,
        -1,
        uid,
        {...bill(uid, date, 'expense', '1'), 'created_at': created},
        [],
        {},
      );
    }
    saveBill(
      data,
      who,
      -1,
      'older',
      bill('已修改', '2026-11-18', 'expense', '2'),
      [],
      {},
    );
    expect(
      data.get(-1, Tables.bill, 'older')!.data['created_at'],
      '2026-11-24 08:00:00',
    );
    expect(monthlyBills(data, -1, '2026-11').map((row) => row.uid), [
      'later-date-later-time',
      'later-date',
      'newer',
      'older',
    ]);
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
    expect(attachmentIds(data, -1, Tables.billAttachment, 'bill'), [
      'concurrent',
    ]);
    expect(data.get(-1, Tables.billAttachment, 'attachment'), isNotNull);
    expect(data.get(-1, Tables.billAttachment, 'concurrent'), isNotNull);
  });
}
