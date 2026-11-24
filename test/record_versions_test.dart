import 'package:flutter_test/flutter_test.dart';
import 'package:gxtodo/controller.dart';
import 'package:gxtodo/domain.dart';
import 'package:gxtodo/ledger.dart';
import 'package:gxtodo/record_versions.dart';
import 'package:gxtodo/reminders.dart';
import 'package:gxtodo/tasks.dart';

import 'memory_repository.dart';

TaskChanges task(String name, {String mode = 'both'}) => TaskChanges(
  name: name,
  project: '',
  place: '',
  rank: 1,
  start: DateTime(2035, 8, 10, 9).millisecondsSinceEpoch ~/ 1000,
  end: DateTime(2035, 8, 10, 10).millisecondsSinceEpoch ~/ 1000,
  allDay: false,
  repeat: 0,
  repeatEnd: 0,
  alert: 0,
  reminderMode: mode,
  remark: '',
  review: '',
  tags: ['测试'],
  children: ['子任务'],
);

void main() {
  const who = Identity.guest;
  test('任务历史还原附件与子任务，回收站恢复原记录、提醒和完成状态', () {
    final data = WorkspaceData();
    final uid = saveTask(
      data,
      who,
      -1,
      null,
      task('第一版'),
      attachments: [
        {'uid': 'file-1', 'kind': 'file', 'media_id': 'original'},
      ],
    );
    final first = recordVersions(data, -1, Tables.task, uid).single;
    saveTask(
      data,
      who,
      -1,
      uid,
      task('第二版', mode: 'notification'),
      removedAttachments: {'file-1'},
    );
    expect(attachmentIds(data, -1, Tables.taskAttachment, uid), isEmpty);
    expect(recordVersions(data, -1, Tables.task, uid), hasLength(2));
    revertTask(
      data,
      who,
      data.get(-1, Tables.task, uid)!,
      versionContents(first),
    );
    final restored = findTask(data, who, -1, uid)!;
    expect(restored.name, '第一版');
    expect(reminderMode(restored.alert), 'both');
    expect(attachmentIds(data, -1, Tables.taskAttachment, uid), ['file-1']);
    toggleTask(data, who, -1, uid, restored.start);
    toggleChild(data, who, -1, uid, restored.children.single);
    deleteTask(data, -1, uid, who: who);
    expect(taskList(data, who, -1), isEmpty);
    final tombstone = data.items[restored.row.key]!;
    expect(tombstone.toUpload()['data']['name'], '第一版');
    data.restore(who, tombstone);
    final recovered = findTask(data, who, -1, uid)!;
    expect(recovered.row.pending, 4);
    expect(recovered.done(who.user, recovered.start), true);
    expect(recovered.childDone(recovered.children.single, who.user), true);
    expect(attachmentIds(data, -1, Tables.taskAttachment, uid), ['file-1']);
  });

  test('账单勾选影响总收入、总支出和支出方，历史还原保留金额精度', () {
    final data = WorkspaceData();
    final bill = {
      'name': '原记录',
      'date': '2026-11-22',
      'type': 'expense',
      'amount': '0.120000001',
      'channel': '微信',
      'party': '微信余额',
    };
    saveBill(data, who, -1, 'expense', bill, [], {});
    final initial = recordVersions(data, -1, Tables.bill, 'expense').single;
    saveBill(
      data,
      who,
      -1,
      'expense',
      {...bill, 'amount': '20.00', 'currency': 'USD', 'include_in_totals': 0},
      [],
      {},
    );
    saveBill(
      data,
      who,
      -1,
      'income',
      {...bill, 'type': 'income', 'amount': '3.99'},
      [],
      {},
    );
    final changed = recordVersions(data, -1, Tables.bill, 'expense').first;
    expect(versionContents(changed)['currency'], 'USD');
    var totals = BillTotals.byCurrency(data.list(-1, Tables.bill))['CNY']!;
    expect(totals.expense.toString(), '0.00');
    expect(totals.parties, isEmpty);
    expect(totals.income.toString(), '3.99');
    revertBill(
      data,
      who,
      data.get(-1, Tables.bill, 'expense')!,
      versionContents(initial)..remove('currency'),
    );
    expect(data.get(-1, Tables.bill, 'expense')!.data['currency'], 'CNY');
    totals = BillTotals.byCurrency(data.list(-1, Tables.bill))['CNY']!;
    expect(totals.expense.toString(), '0.120000001');
    expect(totals.parties['微信余额'].toString(), '0.120000001');
    revertBill(
      data,
      who,
      data.get(-1, Tables.bill, 'expense')!,
      versionContents(changed),
    );
    expect(data.get(-1, Tables.bill, 'expense')!.data['currency'], 'USD');
  });

  test('闹钟与系统通知各自筛选，双提醒同时安排', () async {
    final controller = TodoController(MemoryRepository());
    addTearDown(controller.dispose);
    await controller.initialize();
    for (final mode in ['both', 'alarm', 'notification']) {
      saveTask(controller.data, who, -1, null, task(mode, mode: mode));
    }
    final now = DateTime(2035, 8, 10, 8);
    expect(
      alarmPlan(controller, [], now).map((item) => item.title),
      unorderedEquals(['both', 'alarm']),
    );
    expect(
      alarmPlan(
        controller,
        [],
        now,
        notifications: true,
      ).map((item) => item.title),
      unorderedEquals(['both', 'notification']),
    );
  });
}
