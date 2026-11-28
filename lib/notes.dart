import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'domain.dart';

enum NoteSection {
  quick('速记'),
  essence('精髓'),
  core('内核'),
  diary('日记'),
  info('信息');

  const NoteSection(this.label);
  final String label;
  bool get customFolders => this == diary || this == info;
}

const noteSectionField = 'notebook_section';

List<String> _noteLocation(Item note) =>
    text(note.data[noteSectionField]).split(':');

NoteSection noteSection(Item note) => switch (_noteLocation(note).first) {
  'essence' => NoteSection.essence,
  'core' => NoteSection.core,
  'diary' => NoteSection.diary,
  'info' => NoteSection.info,
  _ => NoteSection.quick,
};

bool isNotebookFolder(Item note) {
  final parts = _noteLocation(note);
  return noteSection(note).customFolders &&
      parts.length > 1 &&
      parts[1] == 'folder';
}

String noteFolderParent(Item note) {
  final parts = _noteLocation(note);
  return noteSection(note).customFolders && parts.length > 2 ? parts[2] : '';
}

typedef NotebookFolder = ({
  String uid,
  String parent,
  int depth,
  String name,
  String path,
});

List<NotebookFolder> notebookFolders(
  WorkspaceData data,
  int team,
  NoteSection section,
) {
  if (!section.customFolders) return [];
  final byParent = <String, List<Item>>{};
  for (final row in data.list(team, Tables.note)) {
    if (noteSection(row) == section && isNotebookFolder(row)) {
      byParent.putIfAbsent(noteFolderParent(row), () => []).add(row);
    }
  }
  final folders = <NotebookFolder>[];
  void visit(String parent, List<String> path, int depth) {
    final children = byParent[parent];
    if (children == null || depth > 3) return;
    children.sort((a, b) => noteTitle(a).compareTo(noteTitle(b)));
    for (final row in children) {
      final name = noteTitle(row);
      final next = [...path, name];
      folders.add((
        uid: row.uid,
        parent: parent,
        depth: depth,
        name: name,
        path: next.join(' / '),
      ));
      visit(row.uid, next, depth + 1);
    }
  }

  visit('', [], 1);
  return folders;
}

void saveNotebookFolder(
  WorkspaceData data,
  Identity who,
  int team,
  NoteSection section,
  String uid,
  String name, {
  String parent = '',
}) {
  final title = name.trim();
  if (!section.customFolders || title.isEmpty || title.length > 100) {
    throw const FormatException('请输入 1 到 100 字的目录名称');
  }
  final folders = notebookFolders(data, team, section);
  final target = folders.where((folder) => folder.uid == parent).firstOrNull;
  if (parent.isNotEmpty && target == null) {
    throw const FormatException('上级目录已失效，请重新选择');
  }
  if (target?.depth == 3) throw const FormatException('目录最多三层');
  if (folders.any(
    (folder) => folder.parent == parent && folder.name == title,
  )) {
    throw const FormatException('同一层已有这个目录');
  }
  data.save(who, team, Tables.note, uid, {
    'name': title,
    'title': title,
    'conversation_version': 1,
    'attachments': '[]',
    'status': 0,
    noteSectionField: '${section.name}:folder:$parent',
  });
}

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
  return '${_dateLabel(value)} ${_pad(value.hour)}:${_pad(value.minute)}';
}

String _pad(int value) => value.toString().padLeft(2, '0');
String _dateLabel(DateTime date) =>
    '${date.year}-${_pad(date.month)}-${_pad(date.day)}';

String notebookTitle(Item note) {
  final created = noteCreated(note);
  final title = noteTitle(note);
  return created == null ? title : '${_dateLabel(created)} $title';
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
  NoteSection section = NoteSection.quick,
  String parentFolder = '',
  Set<String> removed = const {},
}) {
  final isNew = data.get(team, Tables.note, uid) == null;
  if (isNew &&
      section.customFolders &&
      parentFolder.isNotEmpty &&
      !notebookFolders(
        data,
        team,
        section,
      ).any((folder) => folder.uid == parentFolder)) {
    throw const FormatException('目录已失效，请重新选择');
  }
  data.save(who, team, Tables.note, uid, {
    'name': title,
    'title': title,
    'conversation_version': 1,
    'attachments': '[]',
    'status': 0,
    if (section != NoteSection.quick && isNew)
      noteSectionField: section.customFolders && parentFolder.isNotEmpty
          ? '${section.name}:doc:$parentFolder'
          : section.name,
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
