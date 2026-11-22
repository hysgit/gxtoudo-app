import 'dart:convert';

import 'domain.dart';

const attachmentKinds = {'image': '图片', 'audio': '录音', 'file': '文件'};

int versionTable(int table) =>
    table == Tables.task ? Tables.taskVersion : Tables.billVersion;

Iterable<Item> recordAttachments(
  WorkspaceData data,
  int team,
  int table,
  String uid, {
  bool includeDetached = false,
}) => data
    .list(team, table)
    .where(
      (row) =>
          row.data['note_id'] == uid &&
          (includeDetached || integer(row.data['detached']) == 0),
    );

List<String> attachmentIds(
  WorkspaceData data,
  int team,
  int table,
  String uid,
) =>
    recordAttachments(data, team, table, uid).map((row) => row.uid).toList()
      ..sort();

void restoreAttachmentIds(
  WorkspaceData data,
  Identity who,
  int team,
  int table,
  String uid,
  List<Object?> ids,
) {
  for (final row in recordAttachments(
    data,
    team,
    table,
    uid,
    includeDetached: true,
  ).toList()) {
    data.save(who, team, table, row.uid, {
      'detached': ids.contains(row.uid) ? 0 : 1,
    });
  }
}

List<Item> recordVersions(
  WorkspaceData data,
  int team,
  int table,
  String uid,
) =>
    data
        .list(team, versionTable(table))
        .where((row) => row.data['parent_id'] == uid)
        .toList()
      ..sort((a, b) {
        final time = integer(b.data['version_at'])
            .compareTo(integer(a.data['version_at']));
        return time == 0 ? b.uid.compareTo(a.uid) : time;
      });

Fields versionContents(Item row) =>
    fields(jsonDecode(text(row.data['snapshot'])));

void captureVersion(
  WorkspaceData data,
  Identity who,
  int team,
  int table,
  String uid,
  Fields snapshot, {
  String action = '保存',
  bool onlyIfMissing = false,
}) {
  final versions = recordVersions(data, team, table, uid);
  final latest = versions.firstOrNull;
  final encoded = jsonEncode(snapshot);
  if (latest?.data['snapshot'] == encoded &&
      (onlyIfMissing || latest?.data['action'] == action)) {
    return;
  }
  final target = versionTable(table);
  final now = DateTime.now().millisecondsSinceEpoch;
  final last = integer(latest?.data['version_at']);
  data.save(who, team, target, newId(target), {
    'parent_id': uid,
    'snapshot': encoded,
    'version_at': now > last ? now : last + 1,
    'action': action,
  });
}

void saveRecordAttachments(
  WorkspaceData data,
  Identity who,
  int team,
  int table,
  String uid,
  Iterable<Fields> additions,
  Map<String, Fields> media,
  Set<String> removed,
) {
  final parent = table == Tables.taskAttachment ? Tables.task : Tables.bill;
  for (final attachment in additions) {
    final id = text(attachment['uid']);
    if (data.items.containsKey(itemKey(team, table, id))) {
      continue;
    }
    data.save(who, team, table, id, {
      ...attachment,
      'note_id': uid,
      'parent_table': parent,
      'detached': 0,
    });
  }
  for (final id in removed) {
    final row = data.get(team, table, id);
    if (row?.data['note_id'] == uid) {
      data.save(who, team, table, id, {'detached': 1});
    }
  }
  for (final entry in media.entries) {
    data.media[entry.key] = {...entry.value, ...?data.media[entry.key]};
  }
}
