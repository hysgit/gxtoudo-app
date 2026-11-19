import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gxtodo/api.dart';
import 'package:gxtodo/domain.dart';
import 'package:gxtodo/media_files.dart';
import 'package:gxtodo/notes.dart';
import 'package:gxtodo/sync.dart';

import 'memory_repository.dart';

const account = Account(
  server: 'https://example.invalid',
  user: 1,
  login: 1,
  personal: 10,
  token: 'test',
  email: 'local@example.invalid',
  nickname: '本地',
);

class RetryApi extends TodoApi {
  RetryApi() : super(account.server, account);
  bool loseFirstResponse = true;
  int uploads = 0, revision = 0;
  final serverFiles = <String, Fields>{};
  final uploadedRows = <Fields>[];
  final entropies = <Fields>[];
  Future<void> Function()? duringUpload;

  @override
  Future<Fields> uploadMedia(
    File file,
    int team,
    String note,
    String kind,
    String name, {
    String? clientId,
    String? checksum,
  }) async {
    uploads++;
    final metadata = serverFiles.putIfAbsent(
      clientId!,
      () => {
        'id': 'remote-$clientId',
        'sha256': checksum,
        'kind': kind,
        'content_type': kind == 'audio' ? 'audio/mp4' : 'image/png',
        'size': file.lengthSync(),
      },
    );
    await duringUpload?.call();
    if (loseFirstResponse) {
      loseFirstResponse = false;
      throw const ApiFailure('模拟响应丢失');
    }
    return metadata;
  }

  @override
  Future<Fields> call(
    String route, {
    String method = 'POST',
    Fields values = const {},
  }) async {
    if (route == '/team/list') return {'data': []};
    entropies.add(fields(values['entropy']));
    final rows = objects(values['_data']).toList();
    uploadedRows.addAll(rows);
    for (final row in rows) {
      final data = fields(row['data']);
      if (integer(row['table']) == Tables.noteEntry &&
          integer(row['mode']) != 3 &&
          data['kind'] != 'text') {
        expect(text(data['media_id']), isNotEmpty, reason: '附件上传成功之前不能提交媒体消息');
      }
    }
    return {
      'data': [
        for (final row in rows)
          {
            'uid': fields(row['data'])['uid'],
            'status': 0,
            'entropy': ++revision,
          },
      ],
      'down': <Fields>[],
      'down_extra': <Fields>[],
    };
  }
}

void main() {
  late Directory directory;
  late MediaFiles files;
  late MemoryRepository store;
  late Fields media;
  late List<Fields> messages;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('todo-local-first-');
    files = MediaFiles(root: Directory('${directory.path}/persistent'));
    store = MemoryRepository();
    final source = File('${directory.path}/picker-cache.png');
    await source.writeAsBytes([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3]);
    media = await files.importFile(source, 'image');
    await source.delete();
    messages = [
      {'uid': '50-text', 'kind': 'text', 'content': '正文内容', 'entry_at': 1000},
      {
        ...media,
        'uid': '50-image',
        'kind': 'image',
        'media_id': '',
        'entry_at': 2000,
      },
    ];
    await store.change(
      account.identity.scope,
      (data) => saveConversation(
        data,
        account.identity,
        10,
        '49-note',
        '独立标题',
        messages,
        {
          text(media['client_media_id']): {...media, 'team_id': 10},
        },
      ),
    );
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('本地保存不依赖网络，清除相册临时文件和重启后原图仍存在', () async {
    final restarted = await store.read(account.identity.scope);
    final note = restarted.get(10, Tables.note, '49-note')!;
    expect(noteTitle(note), '独立标题');
    expect(noteMessages(restarted, note).map((row) => row.data['kind']), [
      'text',
      'image',
    ]);
    expect(filterNotes([note], data: restarted, query: '正文内容'), [note]);
    final original = await files.file(text(media['client_media_id']), media);
    expect(await original.readAsBytes(), [
      137,
      80,
      78,
      71,
      13,
      10,
      26,
      10,
      1,
      2,
      3,
    ]);
    expect(restarted.media, isNotEmpty);
  });

  test('上传响应丢失后队列保留，重试使用相同附件标识，文字先同步且没有手机路径', () async {
    final api = RetryApi();
    await expectLater(
      synchronize(store, account, client: api, mediaFiles: files),
      throwsA(isA<ApiFailure>()),
    );
    var data = await store.read(account.identity.scope);
    expect(data.get(10, Tables.noteEntry, '50-text')!.pending, 0);
    expect(data.get(10, Tables.noteEntry, '50-image')!.pending, isNot(0));
    expect(api.serverFiles.length, 1);
    await synchronize(store, account, client: api, mediaFiles: files);
    data = await store.read(account.identity.scope);
    expect(data.get(10, Tables.noteEntry, '50-image')!.pending, 0);
    expect(api.uploads, 2);
    expect(api.serverFiles.length, 1);
    expect(api.uploadedRows.toString(), isNot(contains(directory.path)));
    await synchronize(store, account, client: api, mediaFiles: files);
    expect(api.uploads, 2);
  });

  test('上传过程中删除消息，上传回执不会让删除的消息恢复', () async {
    final api = RetryApi()..loseFirstResponse = false;
    api.duringUpload = () => store
        .change(account.identity.scope, (data) {
          data.remove(data.get(10, Tables.noteEntry, '50-image'));
        })
        .then((_) {});
    await synchronize(store, account, client: api, mediaFiles: files);
    final data = await store.read(account.identity.scope);
    expect(data.get(10, Tables.noteEntry, '50-image'), isNull);
  });

  test('旧编辑页再次保存不会擦掉上传回执或并发新增的会话内容', () async {
    final api = RetryApi()..loseFirstResponse = false;
    await synchronize(store, account, client: api, mediaFiles: files);
    await store.change(account.identity.scope, (data) {
      data.save(account.identity, 10, Tables.noteEntry, '50-concurrent', {
        'note_id': '49-note',
        'kind': 'text',
        'content': '另一台设备新增',
        'entry_at': 3000,
      });
      saveConversation(data, account.identity, 10, '49-note', '新标题', messages, {
        text(media['client_media_id']): media,
      });
    });
    final data = await store.read(account.identity.scope);
    expect(data.get(10, Tables.noteEntry, '50-concurrent'), isNotNull);
    expect(
      text(data.get(10, Tables.noteEntry, '50-image')!.data['media_id']),
      isNotEmpty,
    );
    expect(
      text(data.media[text(media['client_media_id'])]!['media_id']),
      isNotEmpty,
    );
  });

  test('本机离线便签导入登录账户后保留附件队列和文件关联', () async {
    final guest = WorkspaceData();
    saveConversation(
      guest,
      Identity.guest,
      -1,
      'guest-note',
      '离线便签',
      messages,
      {
        text(media['client_media_id']): {...media, 'team_id': -1},
      },
    );
    final signedIn = WorkspaceData();
    signedIn.importPersonal(
      account.identity,
      guest.exportPersonal(Identity.guest),
    );
    expect(
      signedIn.get(10, Tables.noteEntry, '50-image')!.data['media_id'],
      '',
    );
    expect(signedIn.media.containsKey(text(media['client_media_id'])), true);
    expect(
      await files.exists(
        text(media['client_media_id']),
        signedIn.media[text(media['client_media_id'])]!,
      ),
      true,
    );
  });

  test('升级后只重拉一次旧游标，补回旧版跳过的消息并保留本地待传内容', () async {
    await store.change(account.identity.scope, (data) {
      data.cursors['t10'] = 99999;
    });
    final api = RetryApi()..loseFirstResponse = false;
    await synchronize(store, account, client: api, mediaFiles: files);
    expect(api.entropies.first['t10'], 0);
    await store.change(account.identity.scope, (data) {
      data.cursors['t10'] = 12;
    });
    await synchronize(store, account, client: api, mediaFiles: files);
    expect(api.entropies.last['t10'], 12);
    final data = await store.read(account.identity.scope);
    expect(data.get(10, Tables.noteEntry, '50-text')!.data['content'], '正文内容');
    expect(await files.exists(text(media['client_media_id']), media), true);
  });
}
