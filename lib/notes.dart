import 'dart:convert';

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
  final first = note.name.trim().split('\n').first;
  if (first.isNotEmpty) return first;
  return noteAttachments(note).any((item) => item['kind'] == 'image')
      ? '图片便签'
      : '语音便签';
}

List<Item> filterNotes(
  Iterable<Item> notes, {
  int? year,
  DateTime? day,
  String query = '',
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
    return note.name.toLowerCase().contains(needle);
  }).toList();
  values.sort(
    (a, b) => (noteCreated(b)?.millisecondsSinceEpoch ?? 0).compareTo(
      noteCreated(a)?.millisecondsSinceEpoch ?? 0,
    ),
  );
  return values;
}
