import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gxtodo/domain.dart';
import 'package:gxtodo/notes.dart';

void main() {
  test('日记和信息使用跨客户端的目录结构，目录最多三层', () {
    final data = WorkspaceData();
    const who = Identity.guest;
    const team = -1;
    const diary = NoteSection.diary;
    saveNotebookFolder(data, who, team, diary, 'first', '随记');
    saveNotebookFolder(data, who, team, diary, 'second', '旅行', parent: 'first');
    saveNotebookFolder(data, who, team, diary, 'third', '照片', parent: 'second');
    expect(
      () => saveNotebookFolder(
        data,
        who,
        team,
        diary,
        'fourth',
        '第四层',
        parent: 'third',
      ),
      throwsFormatException,
    );
    expect(
      () => saveNotebookFolder(
        data,
        who,
        team,
        NoteSection.info,
        'bad',
        '其他栏目录',
        parent: 'first',
      ),
      throwsFormatException,
    );
    saveConversation(
      data,
      who,
      team,
      'doc',
      '自己填写的标题',
      const [],
      const {},
      section: diary,
      parentFolder: 'third',
    );
    final restored = WorkspaceData.fromJson(
      jsonDecode(jsonEncode(data.toJson())),
    );
    final note = restored.get(team, Tables.note, 'doc')!;
    expect(note.data[noteSectionField], 'diary:doc:third');
    expect(noteSection(note), diary);
    expect(noteFolderParent(note), 'third');
    expect(isNotebookFolder(note), isFalse);
    expect(noteTitle(note), '自己填写的标题');
    expect(notebookFolders(restored, team, diary).last.path, '随记 / 旅行 / 照片');
    expect(notebookFolders(restored, team, NoteSection.info), isEmpty);
  });

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
