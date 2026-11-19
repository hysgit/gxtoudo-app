import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gxtodo/domain.dart';
import 'package:gxtodo/notes.dart';

void main() {
  test('编辑文字保留创建时间，筛选使用创建时间而非更新时间', () {
    final data = WorkspaceData();
    const who = Identity.guest;
    data.save(who, -1, Tables.note, 'old', {
      'name': '会议\n下一步计划',
      'created_at': '2024-06-05 00:30:00',
    });
    final changed = data.save(who, -1, Tables.note, 'old', {
      'name': '会议\n新的计划',
    });
    expect(changed.data['created_at'], '2024-06-05 00:30:00');
    expect(filterNotes(data.items.values, year: 2024, query: '新的计划'), [
      changed,
    ]);
    expect(filterNotes(data.items.values, year: 2025), isEmpty);
    final day = noteCreated(changed)!;
    expect(
      filterNotes(
        data.items.values,
        day: DateTime(day.year, day.month, day.day),
      ),
      [changed],
    );
    expect(day.toUtc(), DateTime.utc(2024, 6, 5, 0, 30));
    expect(noteCreatedLabel(changed), startsWith('${day.year}-06-'));
    expect(noteTitle(changed), '会议');
  });

  test('混合附件经过本地持久化仍保持原图元数据和录音关联', () {
    final data = WorkspaceData();
    final note = data.save(Identity.guest, -1, Tables.note, 'mixed', {
      'name': '',
      'attachments': jsonEncode([
        {
          'id': 'image',
          'kind': 'image',
          'name': '原图.heic',
          'sha256': 'abc',
          'size': 1024,
        },
        {
          'id': 'audio',
          'kind': 'audio',
          'name': '录音.m4a',
          'sha256': 'def',
          'size': 2000,
        },
      ]),
    });
    final restored = WorkspaceData.fromJson(
      jsonDecode(jsonEncode(data.toJson())),
    );
    expect(
      noteAttachments(restored.get(-1, Tables.note, note.uid)),
      noteAttachments(note),
    );
    expect(noteTitle(note), '图片便签');
    expect(filterNotes([note]), [note]);
  });
}
