import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import 'appearance.dart';
import 'controller.dart';
import 'domain.dart';

class BackupPage extends StatefulWidget {
  const BackupPage(this.controller, {super.key});
  final TodoController controller;

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  bool busy = false;

  Future<void> run(Future<String?> Function() operation) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final status = await operation();
      if (status != null && mounted) message(context, status);
    } catch (error) {
      if (mounted) message(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<String?> export() async {
    final controller = widget.controller;
    final value = controller.data.exportPersonal(controller.identity);
    final bytes = Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent('  ').convert(value)),
    );
    final date = DateTime.now().toIso8601String().substring(0, 10);
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '保存个人空间备份',
      fileName: 'gxtodo-$date.json',
      bytes: bytes,
    );
    return path == null ? null : '备份已保存';
  }

  Future<String?> import() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    if (result == null) return null;
    final file = result.files.single;
    final bytes = file.bytes;
    if (bytes == null || bytes.length > 16 * 1024 * 1024) {
      throw const FormatException('备份大小超过 16 MB 或无法读取');
    }
    return insert(fields(jsonDecode(utf8.decode(bytes))));
  }

  Future<String> insert(Fields value) async {
    var added = 0;
    await widget.controller.mutate(
      (data, who) => added = data.importPersonal(who, value),
    );
    return '已导入 $added 条记录';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('数据备份')),
    body: PageContent(
      children: [
        FilledButton.icon(
          onPressed: busy ? null : () => run(export),
          icon: const Icon(Icons.file_upload_outlined),
          label: const Text('导出个人空间'),
        ),
        OutlinedButton.icon(
          onPressed: busy ? null : () => run(import),
          icon: const Icon(Icons.file_download_outlined),
          label: const Text('导入备份'),
        ),
        if (widget.controller.account != null)
          OutlinedButton(
            onPressed: busy
                ? null
                : () => run(() async {
                    final guest = await widget.controller.repository.read(
                      Identity.guest.scope,
                    );
                    return insert(guest.exportPersonal(Identity.guest));
                  }),
            child: const Text('导入本机离线数据'),
          ),
      ],
    ),
  );
}
