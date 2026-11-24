import 'package:material_ui/material_ui.dart';

import 'appearance.dart';
import 'controller.dart';
import 'domain.dart';
import 'ledger.dart';
import 'record_versions.dart';
import 'schedule.dart';
import 'tasks.dart';

String _stamp(int milliseconds) {
  final date = DateTime.fromMillisecondsSinceEpoch(milliseconds);
  return '${billDate(date)} ${clock(date)}:${date.second.toString().padLeft(2, '0')}';
}

class RecordHistoryPage extends StatelessWidget {
  const RecordHistoryPage(this.controller, this.record, {super.key});
  final TodoController controller;
  final Item record;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('历史版本')),
    body: ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final versions = recordVersions(
          controller.data,
          record.team,
          record.table,
          record.uid,
        );
        return PageContent(
          children: [
            if (versions.isEmpty) const EmptyContent('保存修改后，历史版本会显示在这里'),
            for (final version in versions)
              ListTile(
                title: Text(_stamp(integer(version.data['version_at']))),
                subtitle: Text(text(version.data['action'])),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showVersion(context, version),
              ),
          ],
        );
      },
    ),
  );

  Future<void> showVersion(BuildContext context, Item version) async {
    final Fields snapshot;
    try {
      snapshot = versionContents(version);
    } on FormatException {
      message(context, '此版本无法读取');
      return;
    }
    final task = record.table == Tables.task;
    final attachmentTable = task
        ? Tables.taskAttachment
        : Tables.billAttachment;
    final ids = snapshot['attachments'];
    final lines = [
      text(snapshot['name']),
      if (task) ...[
        if (integer(snapshot['start']) > 0)
          '开始 ${localTime(integer(snapshot['start'])).toString().substring(0, 16)}',
        if (integer(snapshot['end']) > 0)
          '结束 ${localTime(integer(snapshot['end'])).toString().substring(0, 16)}',
        '优先级 ${integer(snapshot['rank'], 1)}',
        if (snapshot['allDay'] == true) '全天',
        if (integer(snapshot['repeat']) > 0)
          '重复 ${repeatNames[integer(snapshot['repeat']).clamp(0, repeatNames.length - 1)]}',
        if (snapshot['alert'] != null)
          '提醒 ${alarms[integer(snapshot['alert'], -1)] ?? '自定义时间'}',
        if (snapshot['tags'] case final List tags when tags.isNotEmpty)
          '标签 ${tags.join('、')}',
        if (snapshot['children'] case final List children
            when children.isNotEmpty)
          '子任务\n${children.join('\n')}',
        if (text(snapshot['review']).isNotEmpty) '复盘 ${snapshot['review']}',
      ] else ...[
        '${snapshot['date']} · ${billTypes[snapshot['type']]} · '
            '${billAmountLabel(text(snapshot['amount']), billCurrency(snapshot))}',
        '${snapshot['channel']} · ${snapshot['party']}',
        if (text(snapshot['location']).isNotEmpty) text(snapshot['location']),
        if (!billIncluded(snapshot)) '未计入汇总',
      ],
      if (text(snapshot['remark']).isNotEmpty) '备注 ${snapshot['remark']}',
      if (ids is List)
        for (final id in ids)
          text(
            controller.data
                .get(record.team, attachmentTable, text(id))
                ?.data['media_name'],
          ),
    ];
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_stamp(integer(version.data['version_at']))),
        content: SingleChildScrollView(
          child: SelectableText(
            lines.where((line) => line.isNotEmpty).join('\n\n'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          if (controller.data.get(record.team, record.table, record.uid) !=
              null)
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('还原此版本'),
            ),
        ],
      ),
    );
    if (accepted != true || !context.mounted) return;
    try {
      final scope = controller.identity.scope;
      await controller.mutate((data, who) {
        if (scope != who.scope ||
            data.get(version.team, version.table, version.uid) == null) {
          throw const FormatException('版本已变化，请重新打开');
        }
        if (task) {
          revertTask(data, who, record, snapshot);
        } else {
          revertBill(data, who, record, snapshot);
        }
      });
      if (context.mounted) Navigator.pop(context, true);
    } catch (_) {
      if (context.mounted) message(context, '未能还原此版本，请刷新后重试');
    }
  }
}

class RecycleBinPage extends StatelessWidget {
  const RecycleBinPage(this.controller, this.team, {super.key});
  final TodoController controller;
  final int team;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('回收站')),
    body: ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final rows =
            controller.data.items.values
                .where(
                  (row) =>
                      row.team == team &&
                      row.removed &&
                      row.name.isNotEmpty &&
                      Tables.recoverable.contains(row.table),
                )
                .toList()
              ..sort((a, b) => b.edited.compareTo(a.edited));
        return PageContent(
          children: [
            if (rows.isEmpty)
              const EmptyContent('回收站为空', icon: Icons.delete_outline),
            for (final row in rows)
              ListTile(
                title: Text(row.name),
                subtitle: Text(
                  '${row.table == Tables.task ? '任务' : '账单'} · ${_stamp(row.edited)}',
                ),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => RecordHistoryPage(controller, row),
                  ),
                ),
                trailing: TextButton(
                  onPressed: () => restore(context, row),
                  child: const Text('恢复'),
                ),
              ),
          ],
        );
      },
    ),
  );

  Future<void> restore(BuildContext context, Item row) async {
    final scope = controller.identity.scope;
    try {
      await controller.mutate((data, who) {
        final current = data.items[row.key];
        if (scope != who.scope ||
            current == null ||
            current.edited != row.edited ||
            !current.removed) {
          throw const FormatException('记录已变化');
        }
        data.restore(who, current);
        if (row.table == Tables.task) {
          captureTask(
            data,
            who,
            findTask(data, who, team, row.uid)!,
            action: '从回收站恢复',
          );
        } else {
          captureBill(
            data,
            who,
            data.get(team, Tables.bill, row.uid)!,
            action: '从回收站恢复',
          );
        }
      });
      if (context.mounted) message(context, '已恢复');
    } catch (_) {
      if (context.mounted) message(context, '未能恢复，请刷新后重试');
    }
  }
}
