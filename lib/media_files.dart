import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'domain.dart';

/// Original files live in Application Support, never in the OS image-picker cache.
class MediaFiles {
  MediaFiles({this.root});
  final Directory? root;

  Future<Directory> get directory async {
    final value =
        root ??
        Directory(
          '${(await getApplicationSupportDirectory()).path}/note-files',
        );
    return value.create(recursive: true);
  }

  static String extension(Fields media) =>
      switch (text(media['content_type'])) {
        'audio/wav' => '.wav',
        'audio/ogg' => '.ogg',
        'audio/mpeg' => '.mp3',
        'audio/mp4' => '.m4a',
        _ => media['kind'] == 'audio' ? '.m4a' : '.image',
      };

  Future<File> file(String id, Fields media) async {
    final key = sha256.convert(utf8.encode(id)).toString();
    return File('${(await directory).path}/$key${extension(media)}');
  }

  Future<Fields> importFile(File source, String kind, {String? id}) async {
    final size = await source.length();
    if (size <= 0 || size > 100 * 1024 * 1024) {
      throw const ApiFailure('单个文件应为 1 字节至 100 MB');
    }
    final clientId = id ?? newId('media');
    final hash = (await sha256.bind(source.openRead()).first).toString();
    final value = <String, dynamic>{
      'client_media_id': clientId,
      'kind': kind,
      'size': size,
      'sha256': hash,
      'local_ready': 1,
      'content_type': kind == 'audio' ? 'audio/mp4' : '',
    };
    final target = await file(clientId, value);
    final temporary = File('${target.path}.${newId('copy')}.part');
    await source.copy(temporary.path);
    await temporary.rename(target.path);
    return value;
  }

  Future<bool> exists(String id, Fields media) async =>
      (await file(id, media)).exists();

  Future<File?> find(String id, Fields media, String scope) async {
    final target = await file(id, media);
    if (await target.exists()) return target;
    final remote = text(media['media_id'] ?? media['id']);
    if (remote.isEmpty) return null;
    final root = await directory;
    final owner = sha256.convert(utf8.encode(scope));
    final name = sha256.convert(utf8.encode(remote));
    final old = File(
      '${root.parent.path}/note-media/$owner/$name${extension(media)}',
    );
    if (!await old.exists()) return null;
    if ((await sha256.bind(old.openRead()).first).toString() !=
        text(media['sha256'])) {
      return null;
    }
    await old.copy(target.path);
    return target;
  }

  Future<void> download(TodoApi api, String id, Fields metadata) async {
    final target = await file(id, metadata);
    if (await target.exists()) return;
    // Unique temporary names allow a system worker and the foreground to overlap safely.
    final temporary = File('${target.path}.${newId('download')}.part');
    try {
      await api.downloadMedia(
        text(metadata['media_id'] ?? metadata['id']),
        temporary,
      );
      final hash = (await sha256.bind(temporary.openRead()).first).toString();
      if (hash != text(metadata['sha256']) ||
          await temporary.length() != integer(metadata['size'])) {
        throw const ApiFailure('文件下载不完整，将自动重试');
      }
      if (await target.exists()) {
        await temporary.delete();
      } else {
        await temporary.rename(target.path);
      }
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }
}
