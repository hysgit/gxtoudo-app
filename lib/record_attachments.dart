import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'api.dart';
import 'appearance.dart';
import 'controller.dart';
import 'domain.dart';
import 'media_files.dart';
import 'note_bubble.dart';
import 'record_versions.dart';

class AttachmentDraft {
  final additions = <Fields>[];
  final media = <String, Fields>{};
  final removed = <String>{};
}

class RecordAttachments extends StatefulWidget {
  const RecordAttachments({
    required this.controller,
    required this.team,
    required this.table,
    required this.parent,
    required this.draft,
    required this.onState,
    this.files,
    this.locked = false,
    super.key,
  });
  final TodoController controller;
  final int team, table;
  final String parent;
  final AttachmentDraft draft;
  final MediaFiles? files;
  final bool locked;
  final void Function(bool active, bool changed) onState;

  @override
  State<RecordAttachments> createState() => _RecordAttachmentsState();
}

class _RecordAttachmentsState extends State<RecordAttachments>
    with
        WidgetsBindingObserver,
        AutomaticKeepAliveClientMixin<RecordAttachments> {
  late final files = widget.files ?? MediaFiles();
  late final scope = widget.controller.identity.scope;
  AudioRecorder? recorder;
  Timer? timer;
  bool busy = false, recording = false;
  int duration = 0;
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    if (recorder != null) unawaited(recorder!.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && recording) unawaited(stop());
  }

  void activity({required bool work, required bool voice}) {
    if (!mounted) return;
    setState(() {
      busy = work;
      recording = voice;
    });
    widget.onState(busy || recording, false);
  }

  void error(Object value) {
    if (mounted) {
      message(
        context,
        value is ApiFailure ? value.message : '附件操作未完成，请检查权限或本地存储',
      );
    }
  }

  Future<void> add(
    String path,
    String kind,
    String name, {
    int durationMs = 0,
  }) async {
    final meta = await files.importFile(File(path), kind, name: name);
    if (!mounted) return;
    addDraftAttachment(
      widget.draft,
      meta,
      widget.team,
      widget.table,
      widget.parent,
      name: name,
      durationMs: durationMs,
    );
    setState(() {});
    widget.onState(busy || recording, true);
  }

  Future<void> pick(String source) async {
    activity(work: true, voice: false);
    try {
      if (source == 'camera') {
        final value = await ImagePicker().pickImage(
          source: ImageSource.camera,
          imageQuality: 100,
        );
        if (value != null) await add(value.path, 'image', value.name);
      } else {
        final result = await FilePicker.platform.pickFiles(
          type: source == 'image' ? FileType.image : FileType.any,
          allowMultiple: true,
          compressionQuality: 0,
          withData: false,
        );
        for (final file in result?.files ?? <PlatformFile>[]) {
          if (file.path != null) await add(file.path!, source, file.name);
        }
      }
    } catch (value) {
      error(value);
    } finally {
      activity(work: false, voice: false);
    }
  }

  Future<void> record() async {
    if (recording) return stop();
    activity(work: true, voice: false);
    try {
      final audio = recorder ??= AudioRecorder();
      if (!await audio.hasPermission()) {
        if (mounted) message(context, '请允许麦克风权限');
        return;
      }
      final root = await getTemporaryDirectory();
      await audio.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000),
        path: '${root.path}/${newId('voice')}.m4a',
      );
      if (!mounted) return;
      duration = 0;
      activity(work: false, voice: true);
      timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => duration++);
        if (duration >= 3600) unawaited(stop());
      });
    } catch (value) {
      error(value);
    } finally {
      if (!recording) activity(work: false, voice: false);
    }
  }

  Future<void> stop() async {
    if (!recording) return;
    timer?.cancel();
    activity(work: true, voice: false);
    try {
      final path = await recorder!.stop();
      if (path != null) {
        try {
          await add(path, 'audio', '录音.m4a', durationMs: duration * 1000);
        } finally {
          await File(path).delete();
        }
      }
    } catch (value) {
      error(value);
    } finally {
      activity(work: false, voice: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final blocked = widget.locked || busy || recording;
        final draft = widget.draft;
        final data = widget.controller.data;
        final entries = [
          for (final row in recordAttachments(
            data,
            widget.team,
            widget.table,
            widget.parent,
          ))
            if (!draft.removed.contains(row.uid)) {...row.data, 'uid': row.uid},
          ...draft.additions,
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('附件', style: TextStyle(color: muted)),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton.icon(
                  onPressed: blocked ? null : () => pick('image'),
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('相册'),
                ),
                OutlinedButton.icon(
                  onPressed: blocked ? null : () => pick('camera'),
                  icon: const Icon(Icons.camera_alt_outlined),
                  label: const Text('拍照'),
                ),
                OutlinedButton.icon(
                  onPressed: widget.locked || busy ? null : record,
                  icon: Icon(
                    recording ? Icons.stop_circle_outlined : Icons.mic_none,
                  ),
                  label: Text(recording ? '结束录音 $duration 秒' : '录音'),
                ),
                OutlinedButton.icon(
                  onPressed: blocked ? null : () => pick('file'),
                  icon: const Icon(Icons.attach_file),
                  label: const Text('文件'),
                ),
              ],
            ),
            for (final entry in entries)
              Column(
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      tooltip: '移除附件',
                      icon: const Icon(Icons.close),
                      onPressed: blocked
                          ? null
                          : () {
                              setState(() {
                                if (!draft.additions.remove(entry)) {
                                  draft.removed.add(text(entry['uid']));
                                }
                                draft.media.remove(
                                  text(entry['client_media_id']),
                                );
                              });
                              widget.onState(false, true);
                            },
                    ),
                  ),
                  NoteBubble(
                    key: ValueKey(entry['uid']),
                    entry: entry,
                    media: {
                      ...entry,
                      ...?draft.media[text(entry['client_media_id'])],
                      ...?data.media[text(entry['client_media_id'])],
                    },
                    files: files,
                    scope: scope,
                    enabled: !blocked,
                    onLongPress: () {},
                    onRetry: () => unawaited(
                      widget.controller.sync().catchError((Object _) => 0),
                    ),
                  ),
                ],
              ),
          ],
        );
      },
    );
  }
}

void addDraftAttachment(
  AttachmentDraft draft,
  Fields meta,
  int team,
  int table,
  String parent, {
  required String name,
  required int durationMs,
}) {
  final id = text(meta['client_media_id']);
  draft.media[id] = {...meta, 'team_id': team, 'note_id': parent};
  draft.additions.add({
    ...meta,
    'uid': newId(table),
    'note_id': parent,
    'media_id': '',
    'media_name': name,
    'entry_at': DateTime.now().millisecondsSinceEpoch,
    'duration_ms': durationMs,
  });
}
