import 'api.dart';
import 'domain.dart';
import 'media_files.dart';
import 'notes.dart';
import 'repository.dart';

Iterable<Item> mediaMessages(WorkspaceData data, Set<int> active) sync* {
  for (final note in data.items.values) {
    if (note.removed ||
        (note.table != Tables.note && note.table != Tables.bill) ||
        !active.contains(note.team)) {
      continue;
    }
    if (note.table == Tables.bill) {
      yield* data
          .list(note.team, Tables.billAttachment)
          .where((row) => row.data['note_id'] == note.uid);
    } else {
      yield* noteMessages(
        data,
        note,
      ).where((row) => row.data['kind'] != 'text');
    }
  }
}

Future<bool> uploadNoteFiles(
  LocalRepository store,
  Account account,
  TodoApi api,
  MediaFiles files,
  Set<int> active,
) async {
  final scope = account.identity.scope;
  var failed = false;
  final snapshot = await store.read(scope);
  for (final message in mediaMessages(snapshot, active)) {
    if (text(message.data['media_id']).isNotEmpty) continue;
    final id = text(message.data['client_media_id']);
    final local = snapshot.media[id];
    if (local == null) {
      failed = true;
      continue;
    }
    try {
      final file = await files.file(id, local);
      if (!await file.exists()) throw const ApiFailure('本地附件尚未就绪');
      final remote = await api.uploadMedia(
        file,
        message.team,
        text(message.data['note_id']),
        text(message.data['kind']),
        message.data['kind'] == 'audio'
            ? '录音.m4a'
            : message.data['kind'] == 'file'
            ? text(message.data['media_name'])
            : '原图',
        clientId: id,
        checksum: text(local['sha256']),
        parentTable: message.table == Tables.billAttachment
            ? Tables.bill
            : Tables.note,
      );
      if (remote['sha256'] != local['sha256'] ||
          integer(remote['size']) != integer(local['size'])) {
        throw const ApiFailure('附件校验失败');
      }
      await store.change(scope, (data) {
        final metadata = {
          ...local,
          ...remote,
          'media_id': remote['id'],
          'client_media_id': id,
        };
        data.media[id] = metadata;
        // A message removed while uploading must not be resurrected by the receipt.
        final current = data.get(message.team, message.table, message.uid);
        if (current == null || current.data['client_media_id'] != id) return;
        data.save(account.identity, message.team, message.table, current.uid, {
          'media_id': remote['id'],
          'content_type': remote['content_type'],
          'size': remote['size'],
          'sha256': remote['sha256'],
        });
      });
    } catch (_) {
      failed = true;
    }
  }
  return failed;
}

Future<bool> downloadNoteFiles(
  LocalRepository store,
  Account account,
  TodoApi api,
  MediaFiles files,
  Set<int> active,
) async {
  var failed = false;
  final scope = account.identity.scope;
  final snapshot = await store.read(scope);
  for (final message in mediaMessages(snapshot, active)) {
    final metadata = message.data;
    if (text(metadata['media_id']).isEmpty) continue;
    final id = text(metadata['client_media_id']);
    try {
      if (await files.find(id, metadata, scope) == null) {
        await files.download(api, id, metadata);
      }
      await store.change(scope, (data) {
        data.media[id] = {
          ...metadata,
          ...?data.media[id],
          'media_id': metadata['media_id'],
          'local_ready': 1,
          'team_id': message.team,
        };
      });
    } catch (_) {
      failed = true;
    }
  }
  return failed;
}
