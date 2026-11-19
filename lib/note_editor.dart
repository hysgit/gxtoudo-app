import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'api.dart';
import 'appearance.dart';
import 'controller.dart';
import 'domain.dart';
import 'media_files.dart';
import 'note_bubble.dart';
import 'notes.dart';

class NoteEditor extends StatefulWidget {
  const NoteEditor(
    this.controller,
    this.team, {
    super.key,
    this.note,
    this.files,
  });
  final TodoController controller;
  final int team;
  final Item? note;
  final MediaFiles? files;
  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> with WidgetsBindingObserver {
  late final title = TextEditingController(
    text: widget.note == null ? '' : noteTitle(widget.note!),
  );
  final input = TextEditingController();
  final scroll = ScrollController();
  late final uid = widget.note?.uid ?? newId(Tables.note);
  late final scope = widget.controller.identity.scope;
  late final files = widget.files ?? MediaFiles();
  late bool hasSaved = widget.note != null;
  final overrides = <String, Fields>{};
  final localMedia = <String, Fields>{};
  final removed = <String>{};
  final recorder = AudioRecorder();
  final speech = SpeechToText();
  bool busy = false,
      recording = false,
      listening = false,
      dirty = false,
      leaving = false;
  int recordedSeconds = 0;
  String? editing;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    title.addListener(markDirty);
    input.addListener(markDirty);
  }

  void report(Object error) {
    if (!mounted) return;
    final detail = switch (error) {
      ApiFailure failure => failure.message,
      FormatException failure => failure.message,
      FileSystemException _ => '本地文件保存失败，请检查存储空间后重试',
      _ => '操作未完成，请重试',
    };
    message(context, detail);
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
    title.dispose();
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  List<Fields> messages() {
    final data = widget.controller.data;
    final note = data.get(widget.team, Tables.note, uid) ?? widget.note;
    final entries = <String, Fields>{
      if (note != null)
        for (final row in noteMessages(data, note))
          row.uid: {...row.data, 'uid': row.uid},
    };
    for (final entry in overrides.entries) {
      entries[entry.key] = {...?entries[entry.key], ...entry.value};
    }
    final values = entries.entries
        .where((item) => !removed.contains(item.key))
        .map((entry) => entry.value)
        .toList();
    values.sort((a, b) {
      final order = integer(a['entry_at']).compareTo(integer(b['entry_at']));
      return order == 0 ? text(a['uid']).compareTo(text(b['uid'])) : order;
    });
    return values;
  }

  void bottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && scroll.hasClients) {
      scroll.animateTo(
        scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
  });

  Future<void> addFile(
    String path,
    String kind,
    String name, {
    int duration = 0,
  }) async {
    final media = await files.importFile(File(path), kind);
    final id = text(media['client_media_id']);
    if (!mounted) return;
    setState(() {
      localMedia[id] = {...media, 'note_id': uid, 'team_id': widget.team};
      final entry = newId(Tables.noteEntry);
      overrides[entry] = {
        ...media,
        'uid': entry,
        'note_id': uid,
        'media_id': '',
        'media_name': name,
        'duration_ms': duration,
        'entry_at': DateTime.now().millisecondsSinceEpoch,
      };
      dirty = true;
    });
    bottom();
  }

  Future<void> pickImage(bool camera) async {
    FocusScope.of(context).unfocus();
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
      report(error);
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
      report(error);
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
          '录音.m4a',
          duration: recordedSeconds * 1000,
        );
      }
    } catch (error) {
      report(error);
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
      report(error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void appendText() {
    final content = input.text.trim();
    if (content.isEmpty) return;
    final id = editing ?? newId(Tables.noteEntry);
    final previous = messages().where((row) => row['uid'] == id).firstOrNull;
    overrides[id] = {
      ...?previous,
      'uid': id,
      'note_id': uid,
      'kind': 'text',
      'content': content,
      'entry_at':
          previous?['entry_at'] ?? DateTime.now().millisecondsSinceEpoch,
    };
    input.clear();
    editing = null;
  }

  Future<void> save({bool close = true}) async {
    if (busy || recording) return;
    if (title.text.trim().isEmpty) {
      message(context, '请输入便签标题');
      return;
    }
    setState(() => busy = true);
    try {
      await speech.stop();
      appendText();
      final values = messages();
      await widget.controller.mutate((data, who) {
        if (who.scope != scope) throw const ApiFailure('账户已切换，请重新打开便签');
        if (hasSaved && data.get(widget.team, Tables.note, uid) == null) {
          throw const ApiFailure('便签已删除');
        }
        saveConversation(
          data,
          who,
          widget.team,
          uid,
          title.text.trim(),
          values,
          localMedia,
          removed: removed,
        );
      });
      if (!mounted) return;
      setState(() {
        hasSaved = true;
        overrides.clear();
        localMedia.clear();
        removed.clear();
        dirty = false;
        leaving = close;
      });
      if (close) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context);
        });
      } else {
        bottom();
      }
    } catch (error) {
      report(error);
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          listening = false;
        });
      }
    }
  }

  Future<void> messageMenu(Fields entry) async {
    if (busy || recording || listening) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (entry['kind'] == 'text')
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('编辑文字'),
                onTap: () => Navigator.pop(context, 'edit'),
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除这条内容'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'edit') {
      setState(() {
        editing = text(entry['uid']);
        input.text = text(entry['content']);
      });
    } else if (choice == 'delete') {
      setState(() {
        removed.add(text(entry['uid']));
        dirty = true;
      });
      if (hasSaved) await save(close: false);
    }
  }

  Future<void> leave() async {
    if (busy || recording) {
      message(context, '请先结束录音或等待本地保存完成');
      return;
    }
    if (dirty && !await confirm(context, '放弃尚未保存的修改？', '已保存到本机的内容会保留。')) return;
    if (!mounted) return;
    setState(() => leaving = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  Future<void> removeNote() async {
    if (!await confirm(context, '删除便签？', '便签及会话内容将被删除，随后自动同步。')) return;
    if (!mounted) return;
    setState(() => busy = true);
    try {
      await widget.controller.mutate((data, _) {
        data.remove(data.get(widget.team, Tables.note, uid));
        for (final entry in data.list(widget.team, Tables.noteEntry).toList()) {
          if (entry.data['note_id'] == uid) data.remove(entry);
        }
      });
      if (!mounted) return;
      setState(() => leaving = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    } catch (error) {
      report(error);
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
      backgroundColor: const Color(0xffededed),
      appBar: AppBar(
        title: Text(hasSaved ? title.text : '新建便签'),
        actions: [
          if (hasSaved)
            IconButton(
              tooltip: '删除便签',
              onPressed: busy || recording ? null : removeNote,
              icon: const Icon(Icons.delete_outline),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              onPressed: busy || recording ? null : () => save(),
              child: const Text('保存'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextFormField(
                controller: title,
                enabled: !busy,
                maxLength: 100,
                decoration: const InputDecoration(
                  labelText: '便签标题',
                  counterText: '',
                ),
              ),
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: widget.controller,
                builder: (context, _) {
                  final values = messages();
                  if (values.isEmpty) {
                    return const Center(
                      child: Text(
                        '在这里记录文字、图片和语音',
                        style: TextStyle(color: muted),
                      ),
                    );
                  }
                  return ListView.builder(
                    controller: scroll,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    itemCount: values.length,
                    itemBuilder: (context, index) {
                      final entry = values[index];
                      final local =
                          localMedia[text(entry['client_media_id'])] ??
                          widget.controller.data.media[text(
                            entry['client_media_id'],
                          )];
                      return NoteBubble(
                        key: ValueKey(entry['uid']),
                        entry: entry,
                        media: {...entry, ...?local},
                        files: files,
                        scope: scope,
                        enabled: !busy && !recording && !listening,
                        onLongPress: () => messageMenu(entry),
                        onRetry: () {
                          unawaited(
                            widget.controller.sync().catchError((Object error) {
                              if (context.mounted) {
                                message(context, '网络恢复后会自动同步');
                              }
                              return 0;
                            }),
                          );
                        },
                      );
                    },
                  );
                },
              ),
            ),
            if (recording || listening)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  recording
                      ? '正在录音 ${recordedSeconds ~/ 60}:${(recordedSeconds % 60).toString().padLeft(2, '0')}'
                      : '正在语音转文字…',
                ),
              ),
            if (editing != null)
              Row(
                children: [
                  const SizedBox(width: 16),
                  const Text('编辑消息'),
                  IconButton(
                    tooltip: '取消编辑',
                    onPressed: () => setState(() {
                      editing = null;
                      input.clear();
                    }),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ColoredBox(
              color: const Color(0xfff7f7f7),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                child: Column(
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: input,
                            enabled: !busy && !listening,
                            minLines: 1,
                            maxLines: 5,
                            maxLength: 60000,
                            decoration: const InputDecoration(
                              hintText: '输入内容',
                              counterText: '',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: busy || recording || listening
                              ? null
                              : () => save(close: false),
                          child: const Text('发送'),
                        ),
                      ],
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        IconButton(
                          tooltip: '相册原图',
                          onPressed: busy || recording || listening
                              ? null
                              : () => pickImage(false),
                          icon: const Icon(Icons.photo_library_outlined),
                        ),
                        IconButton(
                          tooltip: '拍照',
                          onPressed: busy || recording || listening
                              ? null
                              : () => pickImage(true),
                          icon: const Icon(Icons.camera_alt_outlined),
                        ),
                        IconButton(
                          tooltip: recording ? '结束录音' : '录音',
                          onPressed: busy || listening ? null : toggleRecording,
                          icon: Icon(
                            recording
                                ? Icons.stop_circle_outlined
                                : Icons.mic_none,
                          ),
                        ),
                        IconButton(
                          tooltip: listening ? '结束识别' : '语音转文字',
                          onPressed: busy || recording ? null : dictate,
                          icon: Icon(
                            listening
                                ? Icons.stop_circle_outlined
                                : Icons.keyboard_voice_outlined,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
