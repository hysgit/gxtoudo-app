import 'dart:convert';
import 'dart:math';

import 'api.dart';
import 'domain.dart';
import 'repository.dart';
import 'media_files.dart';
import 'media_sync.dart';

Iterable<Item> _pending(WorkspaceData data, Set<int> active) sync* {
  final pending =
      data.items.values
          .where(
            (row) =>
                row.pending != 0 &&
                active.contains(row.team) &&
                (row.removed ||
                    row.table != Tables.noteEntry ||
                    row.data['kind'] == 'text' ||
                    text(row.data['media_id']).isNotEmpty),
          )
          .toList()
        ..sort((a, b) => a.edited.compareTo(b.edited));
  var bytes = 0;
  for (final item in pending.take(300)) {
    bytes += utf8.encode(jsonEncode(item.toUpload())).length;
    if (bytes > 8 * 1024 * 1024) break;
    yield item;
  }
}

void applyPage(WorkspaceData current, List<Item> sent, Fields reply) {
  if (reply['data'] is! List ||
      reply['down'] is! List ||
      reply['down_extra'] is! List) {
    throw const FormatException('服务端同步响应不完整');
  }
  final batch = {for (final item in sent) item.uid: item};
  final accepted = <String>{};
  for (final ack in objects(reply['data'])) {
    final item = batch[text(ack['uid'] ?? ack['id'])];
    final local = item == null ? null : current.items[item.key];
    final revision = integer(ack['entropy']);
    if (local == null || integer(ack['status'], -1) != 0 || revision <= 0) {
      continue;
    }
    accepted.add(item!.key);
    final pending = local.edited == item.edited
        ? 0
        : local.pending == 1
        ? 2
        : local.pending;
    current.items[local.key] = local.copy(
      revision: max(local.revision, revision),
      pending: pending,
    );
  }
  if (sent.any((item) => !accepted.contains(item.key))) {
    throw const FormatException('服务端未确认全部改动，本机改动已保留');
  }
  final active = {for (final space in current.spaces) space.id};
  for (final update in objects(reply['down'])) {
    final table = integer(update['table_id']);
    final data = fields(update['data']);
    if (table == 12) {
      final space = Space.fromJson(data);
      final index = current.spaces.indexWhere(
        (existing) => existing.id == space.id,
      );
      if (index >= 0 && space.name.isNotEmpty) current.spaces[index] = space;
      continue;
    }
    if (!Tables.all.contains(table)) continue;
    final team = integer(data['team_id']);
    final uid = text(data['uid']);
    final revision = integer(update['sync_entropy']);
    if (!active.contains(team) || uid.isEmpty || revision <= 0) {
      throw const FormatException('服务端下发了无效记录');
    }
    final key = itemKey(team, table, uid);
    final installed = current.items[key];
    if (installed != null &&
        (installed.pending != 0 || installed.revision > revision)) {
      continue;
    }
    final edited = DateTime.tryParse(
      '${text(data['updated_at']).replaceFirst(' ', 'T')}Z',
    );
    current.items[key] = Item(
      table: table,
      team: team,
      uid: uid,
      revision: revision,
      data: data,
      edited: edited?.millisecondsSinceEpoch ?? installed?.edited ?? 0,
      removed: integer(update['edit_mode']) == 3,
    );
  }
  for (final marker in objects(reply['down_extra'])) {
    final team = integer(marker['team_id']);
    final revision = integer(marker['entropy']);
    if (active.contains(team)) current.cursors['t$team'] = revision;
  }
}

Future<int> synchronize(
  LocalRepository store,
  Account account, {
  TodoApi? client,
  MediaFiles? mediaFiles,
  Future<void> Function()? onChanged,
}) async {
  final api = client ?? TodoApi(account.server, account);
  final files = mediaFiles ?? MediaFiles();
  final scope = account.identity.scope;
  final response = await api.call('/team/list', method: 'GET');
  var workspace = await store.change(scope, (workspace) {
    // Older apps advanced their cursors past table 50 without understanding it.
    // Fetch a complete server snapshot once, retaining all pending local edits.
    if (workspace.cursors['note_conversation_version'] != 1) {
      workspace.cursors.removeWhere((key, _) => key.startsWith('t'));
      workspace.cursors['note_conversation_version'] = 1;
    }
    final personal =
        workspace.spaces.where((space) => space.type == 1).firstOrNull ??
        Space(account.personal, '个人空间', 1, account.user);
    workspace.spaces = [
      personal,
      ...objects(response['data'])
          .map(Space.fromJson)
          .where((space) => space.id > 0 && space.type != 1),
    ];
  });
  final active = workspace.spaces.map((space) => space.id).toSet();
  final uploadFailed = await uploadNoteFiles(
    store,
    account,
    api,
    files,
    active,
  );
  workspace = await store.read(scope);
  await onChanged?.call();
  var total = 0;
  for (var page = 0; page < 250; page++) {
    final sent = _pending(workspace, active).toList();
    final reply = await api.call(
      '/sync/do',
      values: {
        'entropy': {
          for (final team in active) 't$team': workspace.cursors['t$team'] ?? 0,
        },
        '_data': sent.map((item) => item.toUpload()).toList(),
      },
    );
    workspace = await store.change(
      scope,
      (current) => applyPage(current, sent, reply),
    );
    await onChanged?.call();
    total += sent.length;
    final hasMore = objects(reply['down_extra'])
        .any((entry) => integer(entry['remain']) > 0);
    if (!hasMore && _pending(workspace, active).isEmpty) {
      final downloadFailed = await downloadNoteFiles(
        store,
        account,
        api,
        files,
        active,
      );
      await onChanged?.call();
      if (uploadFailed ||
          downloadFailed ||
          mediaMessages(
            workspace,
            active,
          ).any((row) => text(row.data['media_id']).isEmpty)) {
        throw const ApiFailure('文字已同步，图片和录音将在网络恢复后自动重试');
      }
      return total;
    }
  }
  throw const ApiFailure('本轮同步达到分页上限，请再同步一次');
}
