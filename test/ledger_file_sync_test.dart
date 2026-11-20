import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gxtodo/api.dart';
import 'package:gxtodo/domain.dart';
import 'package:gxtodo/ledger.dart';
import 'package:gxtodo/media_files.dart';
import 'package:gxtodo/sync.dart';

import 'memory_repository.dart';
import 'note_sync_test.dart' show RetryApi, account;

void main() {
  test('多个账单附件先本地持久化，原文上传后再同步附件记录，断线重试不重复', () async {
    final root = await Directory.systemTemp.createTemp('ledger-files-');
    try {
      final files = MediaFiles(root: Directory('${root.path}/persistent'));
      final store = MemoryRepository();
      final attachments = <Fields>[];
      final index = <String, Fields>{};
      for (final kind in ['file', 'image', 'audio']) {
        final source = File('${root.path}/temporary-$kind');
        await source.writeAsBytes([1, 2, 3, 4, 5]);
        final metadata = await files.importFile(
          source,
          kind,
          name: kind == 'file' ? '收据.PDF' : '附件',
        );
        await source.delete();
        final id = text(metadata['client_media_id']);
        index[id] = {...metadata, 'team_id': 10};
        attachments.add({
          ...metadata,
          'uid': newId(Tables.billAttachment),
          'kind': kind,
          'note_id': 'bill',
          'media_name': kind == 'file' ? '收据.PDF' : '附件',
          'entry_at': 1,
          'media_id': '',
        });
        expect(await files.exists(id, metadata), true);
      }
      await store.change(
        account.identity.scope,
        (data) => saveBill(
          data,
          account.identity,
          10,
          'bill',
          {
            'name': '测试账单',
            'date': '2026-11-20',
            'type': 'expense',
            'amount': '1.2300',
            'channel': '微信',
            'party': '微信余额',
          },
          attachments,
          index,
        ),
      );
      final api = RetryApi();
      await expectLater(
        synchronize(store, account, client: api, mediaFiles: files),
        throwsA(isA<ApiFailure>()),
      );
      await synchronize(store, account, client: api, mediaFiles: files);
      final data = await store.read(account.identity.scope);
      expect(data.get(10, Tables.bill, 'bill')!.data['amount'], '1.2300');
      expect(data.list(10, Tables.billAttachment).length, 3);
      expect(
        data
            .list(10, Tables.billAttachment)
            .every(
              (row) =>
                  row.pending == 0 && text(row.data['media_id']).isNotEmpty,
            ),
        true,
      );
      expect(api.parentTables.every((table) => table == Tables.bill), true);
      expect(api.serverFiles.length, 3);
      final file = data
          .list(10, Tables.billAttachment)
          .firstWhere((row) => row.data['kind'] == 'file');
      final cached = await files.file(
        text(file.data['client_media_id']),
        file.data,
      );
      expect(cached.path.endsWith('.pdf'), true);
      expect(await cached.readAsBytes(), [1, 2, 3, 4, 5]);
      expect(api.uploadedRows.toString(), isNot(contains(root.path)));
    } finally {
      await root.delete(recursive: true);
    }
  });
}
