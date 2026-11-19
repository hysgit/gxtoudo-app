import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'api.dart';
import 'appearance.dart';
import 'controller.dart';
import 'domain.dart';
import 'notes.dart';

class NoteEditor extends StatefulWidget {
  const NoteEditor(this.controller, this.team, {super.key, this.note});
  final TodoController controller;
  final int team;
  final Item? note;

  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _Attachment {
  _Attachment(this.data, [this.file]);
  Fields data;
  File? file;
}

class _NoteEditorState extends State<NoteEditor> with WidgetsBindingObserver {
  late final input = TextEditingController(text: widget.note?.name);
  late final uid = widget.note?.uid ?? newId(Tables.note);
  late final scope = widget.controller.identity.scope;
  late final attachments = noteAttachments(widget.note)
      .map((data) => _Attachment(data))
      .toList();
  final recorder = AudioRecorder();
  final speech = SpeechToText();
  bool busy = false,
      recording = false,
      listening = false,
      dirty = false,
      leaving = false;
  int recordedSeconds = 0;
  Timer? timer;
  String progress = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    input.addListener(markDirty);
  }

  void markDirty() {
    if (!dirty && mounted) setState(() => dirty = true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      if (recording) unawaited(stopRecording());
      if (listening) unawaited(speech.stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    unawaited(recorder.dispose());
    unawaited(speech.cancel());
    input.dispose();
    super.dispose();
  }

  Future<void> addFile(String path, String kind, String name) async {
    if (attachments.length >= 30) throw const ApiFailure('每条便签最多保存 30 个附件');
    final file = File(path);
    final size = await file.length();
    if (size == 0 || size > 100 * 1024 * 1024) {
      throw const ApiFailure('单个附件应为 1 字节至 100 MB');
    }
    if (!mounted) return;
    setState(() {
      attachments.add(
        _Attachment({'kind': kind, 'name': name, 'size': size}, file),
      );
      dirty = true;
    });
  }

  Future<void> pickImage(bool camera) async {
    setState(() => busy = true);
    try {
      if (camera) {
        final image = await ImagePicker().pickImage(
          source: ImageSource.camera,
          imageQuality: 100,
        );
        if (image != null) await addFile(image.path, 'image', image.name);
      } else {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.image,
          allowMultiple: true,
          compressionQuality: 0,
          withData: false,
        );
        for (final file in result?.files ?? <PlatformFile>[]) {
          if (file.path != null) await addFile(file.path!, 'image', file.name);
        }
      }
    } catch (error) {
      if (mounted) message(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> toggleRecording() async {
    if (recording) return stopRecording();
    setState(() => busy = true);
    try {
      if (!await recorder.hasPermission()) {
        throw const ApiFailure('请在系统设置中允许麦克风权限');
      }
      await speech.stop();
      final directory = await getTemporaryDirectory();
      await recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 44100,
        ),
        path: '${directory.path}/${newId('voice')}.m4a',
      );
      if (!mounted) return;
      setState(() {
        recording = true;
        recordedSeconds = 0;
        listening = false;
      });
      timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => recordedSeconds++);
        if (recordedSeconds >= 3600) unawaited(stopRecording());
      });
    } catch (error) {
      if (mounted) message(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> stopRecording() async {
    if (!recording) return;
    timer?.cancel();
    setState(() {
      busy = true;
      recording = false;
    });
    try {
      final path = await recorder.stop();
      if (path != null) {
        await addFile(
          path,
          'audio',
          '录音 ${DateTime.now().toLocal().toString().substring(0, 19)}.m4a',
        );
      }
    } catch (error) {
      if (mounted) message(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> dictate() async {
    if (listening) {
      await speech.stop();
      if (mounted) setState(() => listening = false);
      return;
    }
    setState(() => busy = true);
    try {
      final available = await speech.initialize(
        onStatus: (status) {
          if (mounted && (status == 'done' || status == 'notListening')) {
            setState(() => listening = false);
          }
        },
        onError: (error) {
          if (!mounted) return;
          setState(() => listening = false);
          message(context, '语音识别未完成，请检查系统语音识别权限和网络后重试');
        },
      );
      if (!available) throw const ApiFailure('系统语音识别不可用，请检查麦克风和语音识别权限');
      final locales = await speech.locales();
      final chinese =
          locales
              .where(
                (value) =>
                    value.localeId.replaceAll('-', '_').toLowerCase() ==
                    'zh_cn',
              )
              .firstOrNull ??
          locales.where((value) => value.localeId.startsWith('zh')).firstOrNull;
      final selection = input.selection;
      final start = selection.isValid ? selection.start : input.text.length;
      final end = selection.isValid ? selection.end : input.text.length;
      final prefix = input.text.substring(0, start);
      final suffix = input.text.substring(end);
      await speech.listen(
        listenOptions: SpeechListenOptions(
          localeId: chinese?.localeId,
          listenMode: ListenMode.dictation,
          partialResults: true,
          cancelOnError: true,
        ),
        onResult: (result) {
          if (!mounted) return;
          final words = result.recognizedWords;
          if (prefix.length + words.length + suffix.length > 60000) return;
          input.value = TextEditingValue(
            text: '$prefix$words$suffix',
            selection: TextSelection.collapsed(
              offset: prefix.length + words.length,
            ),
          );
        },
      );
      if (mounted) setState(() => listening = speech.isListening);
    } catch (error) {
      if (mounted) message(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    if (busy || recording) return;
    if (input.text.trim().isEmpty && attachments.isEmpty) {
      message(context, '请输入文字或添加图片、录音');
      return;
    }
    if (input.text.length > 60000) {
      message(context, '便签文字最多 60000 字');
      return;
    }
    setState(() => busy = true);
    try {
      await speech.stop();
      final api = widget.controller.api;
      for (var i = 0; i < attachments.length; i++) {
        final attachment = attachments[i];
        if (text(attachment.data['id']).isNotEmpty) continue;
        if (mounted) {
          setState(() => progress = '正在上传附件 ${i + 1}/${attachments.length}');
        }
        final file = attachment.file!;
        final metadata = await api.uploadMedia(
          file,
          widget.team,
          uid,
          text(attachment.data['kind']),
          text(attachment.data['name']),
        );
        final hash = (await sha256.bind(file.openRead()).first).toString();
        if (hash != text(metadata['sha256'])) {
          throw const ApiFailure('附件校验失败，请重新上传');
        }
        attachment.data = metadata;
      }
      if (widget.controller.identity.scope != scope) {
        throw const ApiFailure('账户已切换，请重新打开便签');
      }
      await widget.controller.mutate((workspace, who) {
        if (who.scope != scope) {
          throw const ApiFailure('账户已切换，请重新打开便签');
        }
        if (widget.note != null &&
            workspace.get(widget.team, Tables.note, uid) == null) {
          throw const ApiFailure('便签已删除');
        }
        workspace.save(who, widget.team, Tables.note, uid, {
          'name': input.text,
          'sequence':
              widget.note?.data['sequence'] ??
              DateTime.now().millisecondsSinceEpoch,
          'status': 0,
          'attachments': jsonEncode(
            attachments.map((item) => item.data).toList(),
          ),
        });
      });
      if (mounted) {
        setState(() => leaving = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context);
        });
      }
    } catch (error) {
      if (mounted) message(context, error);
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          progress = '';
          listening = false;
        });
      }
    }
  }

  Future<void> leave() async {
    if (busy || recording) {
      message(context, '请先结束录音或等待保存完成');
      return;
    }
    if (dirty && !await confirm(context, '放弃修改？', '尚未保存的文字和附件将被放弃。')) return;
    if (!mounted) return;
    setState(() => leaving = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  Future<void> remove() async {
    if (!await confirm(context, '删除便签？', '这条便签的文字、图片和录音将不再显示。')) return;
    if (!mounted) return;
    setState(() => busy = true);
    try {
      await widget.controller.mutate((data, _) => data.remove(widget.note));
      if (mounted) {
        setState(() => leaving = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context);
        });
      }
    } catch (error) {
      if (mounted) message(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: leaving || (!dirty && !busy && !recording),
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(leave());
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(widget.note == null ? '新建便签' : '编辑便签'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              onPressed: busy || recording ? null : save,
              child: busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('保存'),
            ),
          ),
        ],
      ),
      body: PageContent(
        children: [
          if (widget.note != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                noteCreatedLabel(widget.note!),
                style: const TextStyle(color: muted),
              ),
            ),
          TextFormField(
            controller: input,
            enabled: !busy && !listening,
            decoration: const InputDecoration(labelText: '便签内容'),
            minLines: 7,
            maxLines: 18,
            maxLength: 60000,
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: busy || recording || listening
                    ? null
                    : () => pickImage(false),
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('相册原图'),
              ),
              OutlinedButton.icon(
                onPressed: busy || recording || listening
                    ? null
                    : () => pickImage(true),
                icon: const Icon(Icons.camera_alt_outlined),
                label: const Text('拍照'),
              ),
              OutlinedButton.icon(
                onPressed: busy || listening ? null : toggleRecording,
                icon: Icon(
                  recording ? Icons.stop_circle_outlined : Icons.mic_none,
                ),
                label: Text(
                  recording
                      ? '结束录音 ${recordedSeconds ~/ 60}:${(recordedSeconds % 60).toString().padLeft(2, '0')}'
                      : '录音',
                ),
              ),
              OutlinedButton.icon(
                onPressed: busy || recording ? null : dictate,
                icon: Icon(
                  listening
                      ? Icons.stop_circle_outlined
                      : Icons.keyboard_voice_outlined,
                ),
                label: Text(listening ? '结束识别' : '语音转文字'),
              ),
            ],
          ),
          if (progress.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(progress),
            ),
          const SizedBox(height: 16),
          for (final attachment in attachments)
            NoteAttachmentTile(
              key: ObjectKey(attachment),
              api: widget.controller.api,
              data: attachment.data,
              localFile: attachment.file,
              enabled: !busy && !recording && !listening,
              onRemove: busy || recording || listening
                  ? null
                  : () => setState(() {
                      attachments.remove(attachment);
                      dirty = true;
                    }),
            ),
          if (widget.note != null)
            TextButton(
              onPressed: busy || recording || listening ? null : remove,
              child: Text(
                '删除便签',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    ),
  );
}

class NoteAttachmentTile extends StatefulWidget {
  const NoteAttachmentTile({
    super.key,
    required this.api,
    required this.data,
    this.localFile,
    this.onRemove,
    this.enabled = true,
  });
  final TodoApi api;
  final Fields data;
  final File? localFile;
  final VoidCallback? onRemove;
  final bool enabled;

  @override
  State<NoteAttachmentTile> createState() => _NoteAttachmentTileState();
}

class _NoteAttachmentTileState extends State<NoteAttachmentTile> {
  late Future<File> file = load();
  final player = AudioPlayer();
  bool loadingAudio = false;

  Future<File> load() async {
    if (widget.localFile != null) return widget.localFile!;
    final account = widget.api.account;
    if (account == null) throw const ApiFailure('请登录后读取附件');
    final root = await getApplicationSupportDirectory();
    final scope = sha256
        .convert(utf8.encode(account.identity.scope))
        .toString();
    final directory = Directory('${root.path}/note-media/$scope');
    await directory.create(recursive: true);
    final id = text(widget.data['id']);
    final key = sha256.convert(utf8.encode(id)).toString();
    final extension = widget.data['kind'] == 'audio' ? '.m4a' : '.image';
    final cached = File('${directory.path}/$key$extension');
    if (await cached.exists()) return cached;
    final temporary = File('${cached.path}.${newId('download')}.part');
    try {
      await widget.api.downloadMedia(id, temporary);
      final hash = (await sha256.bind(temporary.openRead()).first).toString();
      if (hash != text(widget.data['sha256']) ||
          await temporary.length() != integer(widget.data['size'])) {
        throw const ApiFailure('附件下载不完整，请重试');
      }
      await temporary.rename(cached.path);
      return cached;
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  Future<void> play(File audio) async {
    if (loadingAudio) return;
    if (player.playing) {
      await player.pause();
      return;
    }
    setState(() => loadingAudio = true);
    try {
      if (player.audioSource == null) await player.setFilePath(audio.path);
      if (player.processingState == ProcessingState.completed) {
        await player.seek(Duration.zero);
      }
      unawaited(
        player.play().catchError((Object error) {
          if (mounted) message(context, '无法播放录音，请重试');
        }),
      );
    } catch (error) {
      if (mounted) message(context, '无法播放录音，请重试');
    } finally {
      if (mounted) setState(() => loadingAudio = false);
    }
  }

  @override
  void dispose() {
    unawaited(player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    text(widget.data['name']),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: '移除附件',
                  onPressed: widget.onRemove,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            FutureBuilder<File>(
              future: file,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return TextButton.icon(
                    onPressed: () => setState(() => file = load()),
                    icon: const Icon(Icons.refresh),
                    label: const Text('附件加载失败，点击重试'),
                  );
                }
                final value = snapshot.data;
                if (value == null) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (widget.data['kind'] == 'image') {
                  return InkWell(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => Scaffold(
                          appBar: AppBar(title: const Text('原图')),
                          body: Center(
                            child: InteractiveViewer(
                              minScale: 0.5,
                              maxScale: 8,
                              child: Image.file(
                                value,
                                errorBuilder: (_, _, _) =>
                                    const Text('系统暂不支持预览此图片格式'),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    child: Image.file(
                      value,
                      height: 180,
                      fit: BoxFit.contain,
                      cacheWidth: 720,
                      semanticLabel: '便签图片，点击查看原图',
                      errorBuilder: (_, _, _) =>
                          const Text('原图已保存，系统暂不支持预览此格式'),
                    ),
                  );
                }
                return StreamBuilder<PlayerState>(
                  stream: player.playerStateStream,
                  builder: (context, state) => Column(
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: !widget.enabled || loadingAudio
                            ? null
                            : () => play(value),
                        icon: Icon(
                          state.data?.playing == true
                              ? Icons.pause
                              : Icons.play_arrow,
                        ),
                        label: Text(
                          loadingAudio
                              ? '正在加载'
                              : state.data?.playing == true
                              ? '暂停'
                              : '播放录音',
                        ),
                      ),
                      StreamBuilder<Duration>(
                        stream: player.positionStream,
                        builder: (_, position) {
                          final duration = player.duration?.inMilliseconds ?? 0;
                          return Slider(
                            value: (position.data?.inMilliseconds ?? 0)
                                .clamp(0, duration)
                                .toDouble(),
                            max: duration > 0 ? duration.toDouble() : 1,
                            onChanged: duration > 0
                                ? (value) => player.seek(
                                    Duration(milliseconds: value.round()),
                                  )
                                : null,
                          );
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    ),
  );
}
