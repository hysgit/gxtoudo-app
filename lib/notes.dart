import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'domain.dart';

List<Fields> noteAttachments(Item? note) {
  final raw = text(note?.data['attachments']);
  if (raw.isEmpty) return [];
  return objects(jsonDecode(raw)).map((item) => {...item}).toList();
}

DateTime? noteCreated(Item note) {
  final raw = text(note.data['created_at']);
  if (raw.isEmpty) return null;
  // The synchronization protocol stores UTC timestamps without a zone suffix.
  return DateTime.tryParse('${raw.replaceFirst(' ', 'T')}Z')?.toLocal();
}

String noteCreatedLabel(Item note) {
  final value = noteCreated(note);
  if (value == null) return '创建时间未知';
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${value.year}-${pad(value.month)}-${pad(value.day)} '
      '${pad(value.hour)}:${pad(value.minute)}';
}

String noteTitle(Item note) {
  final explicit = text(note.data['title']).trim();
  if (explicit.isNotEmpty) return explicit;
  final first = note.name.trim().split('\n').first;
  if (first.isNotEmpty) return first;
  return noteAttachments(note).any((item) => item['kind'] == 'image')
      ? '图片便签'
      : '语音便签';
}

String messageTime(Fields message) {
  final at = integer(message['entry_at']);
  final value = DateTime.fromMillisecondsSinceEpoch(at).toLocal();
  String pad(int n) => '$n'.padLeft(2, '0');
  return '${value.year}-${pad(value.month)}-${pad(value.day)} ${pad(value.hour)}:${pad(value.minute)}:${pad(value.second)}';
}

List<Item> noteMessages(WorkspaceData data, Item note) {
  final values = data
      .list(note.team, Tables.noteEntry)
      .where((row) => row.data['note_id'] == note.uid)
      .toList();
  if (integer(note.data['conversation_version']) == 0) {
    final at = noteCreated(note)?.millisecondsSinceEpoch ?? note.edited;
    String id(String part) =>
        '50-${sha256.convert(utf8.encode('${note.team}:${note.uid}:$part'))}';
    if (note.name.trim().isNotEmpty) {
      values.add(
        Item(
          table: Tables.noteEntry,
          team: note.team,
          uid: id('text'),
          data: {
            'note_id': note.uid,
            'kind': 'text',
            'content': note.name,
            'entry_at': at,
          },
        ),
      );
    }
    for (final (index, media) in noteAttachments(note).indexed) {
      values.add(
        Item(
          table: Tables.noteEntry,
          team: note.team,
          uid: id('media-${media['id']}'),
          data: {
            ...media,
            'note_id': note.uid,
            'media_id': media['id'],
            'client_media_id': 'remote-${media['id']}',
            'entry_at': at + index + 1,
          },
        ),
      );
    }
  }
  values.sort((a, b) {
    final order = integer(a.data['entry_at'])
        .compareTo(integer(b.data['entry_at']));
    return order == 0 ? a.uid.compareTo(b.uid) : order;
  });
  return values;
}

String noteSearchText(WorkspaceData data, Item note) => [
  noteTitle(note),
  ...noteMessages(data, note)
      .where((row) => row.data['kind'] == 'text')
      .map((row) => text(row.data['content'])),
].join('\n');

void saveConversation(
  WorkspaceData data,
  Identity who,
  int team,
  String uid,
  String title,
  List<Fields> messages,
  Map<String, Fields> localMedia, {
  Set<String> removed = const {},
}) {
  data.save(who, team, Tables.note, uid, {
    'name': title,
    'title': title,
    'conversation_version': 1,
    'attachments': '[]',
    'status': 0,
  });
  for (final message in messages) {
    final id = text(message['uid']);
    if (data.items[itemKey(team, Tables.noteEntry, id)]?.removed == true) {
      throw const FormatException('这条内容已删除，请重新打开便签');
    }
    final current = data.get(team, Tables.noteEntry, id);
    final value = {...message, 'note_id': uid};
    if (current != null &&
        text(current.data['media_id']).isNotEmpty &&
        current.data['client_media_id'] == message['client_media_id']) {
      for (final key in ['media_id', 'content_type', 'size', 'sha256']) {
        value[key] = current.data[key];
      }
    }
    data.save(who, team, Tables.noteEntry, id, value);
  }
  for (final id in removed) {
    final row = data.get(team, Tables.noteEntry, id);
    if (row?.data['note_id'] == uid) data.remove(row);
  }
  for (final entry in localMedia.entries) {
    // Upload responses may have arrived while this editor was open.
    data.media[entry.key] = {...entry.value, ...?data.media[entry.key]};
  }
}

List<Item> filterNotes(
  Iterable<Item> notes, {
  int? year,
  DateTime? day,
  String query = '',
  WorkspaceData? data,
}) {
  final needle = query.trim().toLowerCase();
  final values = notes.where((note) {
    final created = noteCreated(note);
    if (year != null && created?.year != year) return false;
    if (day != null &&
        (created == null ||
            created.year != day.year ||
            created.month != day.month ||
            created.day != day.day)) {
      return false;
    }
    return (data == null ? note.name : noteSearchText(data, note))
        .toLowerCase()
        .contains(needle);
  }).toList();
  values.sort(
    (a, b) => (noteCreated(b)?.millisecondsSinceEpoch ?? 0).compareTo(
      noteCreated(a)?.millisecondsSinceEpoch ?? 0,
    ),
  );
  return values;
}
