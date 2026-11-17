import 'package:flutter_test/flutter_test.dart';
import 'package:gxtodo/api.dart';
import 'package:gxtodo/domain.dart';
import 'package:gxtodo/schedule.dart';
import 'package:gxtodo/sync.dart';
import 'package:gxtodo/tasks.dart';

void main() {
  test('默认服务端地址使用指定的 Codemagic 部署 API', () {
    expect(defaultServer, 'https://tudosrv.woslx.com');
    expect(serverOrigin(defaultServer), 'https://tudosrv.woslx.com');
    expect(
      () => serverOrigin('http://116.62.150.127:18019'),
      throwsFormatException,
    );
    expect(() => serverOrigin('http://example.com:18019'), throwsFormatException);
    expect(serverOrigin('https://todo.example.com'), 'https://todo.example.com');
  });

  test('重复任务按本地日历计算，月末和结束日期正确', () {
    final start = seconds(DateTime(2026, 1, 31, 9, 30));
    final repeat = recurrence(4, start, seconds(DateTime(2026, 3, 31, 23, 59)));
    expect(localTime(occurs(start, repeat, DateTime(2026, 2, 28))).hour, 9);
    expect(occurs(start, repeat, DateTime(2026, 3, 30)), 0);
    expect(occurs(start, repeat, DateTime(2026, 4, 30)), 0);
    final week = recurrence(3, seconds(DateTime(2026, 11, 16, 9)), 0);
    expect(
      occurs(integer(week['repeat_start']), week, DateTime(2026, 11, 21)),
      0,
    );
    expect(
      occurs(integer(week['repeat_start']), week, DateTime(2026, 11, 23)),
      greaterThan(0),
    );
  });

  test('收到在途同步确认时保留本机后续编辑', () {
    const who = Identity('A', 7, 21);
    final data = WorkspaceData(spaces: [const Space(21, '个人空间', 1, 7)]);
    final sent = data.save(who, 21, Tables.note, 'n', {'name': '第一版'});
    final later = data.save(who, 21, Tables.note, 'n', {'name': '第二版'});
    applyPage(
      data,
      [sent],
      {
        'data': [
          {'uid': 'n', 'status': 0, 'entropy': 12},
        ],
        'down': [
          {
            'table_id': Tables.note,
            'sync_entropy': 12,
            'edit_mode': 1,
            'data': sent.data,
          },
        ],
        'down_extra': [
          {'team_id': 21, 'entropy': 12},
        ],
      },
    );
    final item = data.get(21, Tables.note, 'n')!;
    expect(item.name, later.name);
    expect(item.pending, 2);
    expect(item.revision, 12);
    expect(data.cursors['t21'], 12);
  });

  test('完成重复日程的一次不会完成后续日程，备份迁移到个人空间', () {
    const who = Identity.guest;
    final data = WorkspaceData();
    final start = seconds(DateTime(2026, 11, 17, 9));
    saveTask(
      data,
      who,
      -1,
      null,
      TaskChanges(
        name: '晨练',
        rank: 2,
        project: '',
        place: '',
        start: start,
        end: start + 3600,
        allDay: false,
        repeat: 1,
        repeatEnd: 0,
        alert: 600,
        remark: '',
        review: '',
        tags: ['习惯'],
        children: ['热身'],
      ),
    );
    final task = taskList(data, who, -1).single;
    toggleTask(data, who, -1, task.uid, start);
    final checked = taskList(data, who, -1).single;
    expect(checked.done(0, start), isTrue);
    expect(checked.done(0, checked.on(DateTime(2026, 11, 18))), isFalse);
    final copy = WorkspaceData();
    const signed = Identity('other', 5, 11);
    final backup = data.exportPersonal(who);
    expect(copy.importPersonal(signed, backup), greaterThan(0));
    expect(copy.importPersonal(signed, backup), 0);
    expect(taskList(copy, signed, 11).single.done(5, start), isTrue);
  });
}
