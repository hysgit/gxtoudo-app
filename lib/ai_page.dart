import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'api.dart';
import 'appearance.dart';
import 'controller.dart';
import 'dictation.dart';
import 'domain.dart';

class AiPage extends StatefulWidget {
  const AiPage(
    this.controller, {
    required this.onLogin,
    required this.openRecord,
    super.key,
  });
  final TodoController controller;
  final VoidCallback onLogin;
  final ValueChanged<Fields> openRecord;

  @override
  State<AiPage> createState() => _AiPageState();
}

class _AiPageState extends State<AiPage> {
  final input = TextEditingController();
  final scroll = ScrollController(keepScrollOffset: false);
  final speech = SpeechToText();
  var thread = newId('chat');
  List<Fields> turns = [];
  List<Fields> conversations = [];
  String error = '', model = '';
  bool loading = true, busy = false, configured = false, fetching = false;
  bool preparing = false, listening = false;
  Uint8List? draftImage, pendingImage;
  int pendingImageTurn = 0;
  Timer? timer;
  String? pendingQuestion, requestId;

  @override
  void initState() {
    super.initState();
    if (widget.controller.account != null) {
      unawaited(loadConversations(initial: true));
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    if (speech.isListening) unawaited(speech.cancel());
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> loadConversations({bool initial = false}) async {
    try {
      final reply = await widget.controller.api.call('/ai/chat', method: 'GET');
      if (!mounted) return;
      setState(() {
        model = text(reply['model']);
        configured = reply['configured'] == true;
        conversations = objects(reply['data']).toList();
        if (initial && conversations.isNotEmpty) {
          thread = text(conversations.first['thread']);
        }
        error = '';
        loading = false;
      });
      if (initial) await refresh(bottom: true);
    } catch (failure) {
      if (mounted) {
        setState(() {
          error = failure.toString();
          loading = false;
        });
      }
    }
  }

  bool get pending =>
      turns.any((line) => ['queued', 'running'].contains(line['state']));

  void follow() {
    timer?.cancel();
    if (pending) {
      timer = Timer(const Duration(seconds: 3), () => unawaited(refresh()));
    }
  }

  Future<void> refresh({bool bottom = false}) async {
    if (fetching && !bottom) return;
    fetching = true;
    final selected = thread;
    final wasPending = pending;
    try {
      final reply = await widget.controller.api.call(
        '/ai/chat',
        method: 'GET',
        values: {'thread': selected},
      );
      if (!mounted || selected != thread) return;
      setState(() {
        turns = objects(reply['data']).toList();
        error = '';
      });
      if (bottom || wasPending && !pending) scrollToBottom();
    } catch (failure) {
      if (mounted && selected == thread) {
        setState(() => error = failure.toString());
      }
    } finally {
      fetching = false;
      if (mounted && selected == thread) follow();
    }
  }

  void scrollToBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!scroll.hasClients) return;
    final position = scroll.position;
    scroll.jumpTo(
      turns.isEmpty ? position.maxScrollExtent : position.minScrollExtent,
    );
  });

  void choose(String value) {
    timer?.cancel();
    setState(() {
      thread = value;
      turns = [];
      error = '';
      pendingQuestion = requestId = null;
      draftImage = pendingImage = null;
      pendingImageTurn = 0;
      input.clear();
    });
    unawaited(refresh(bottom: true));
  }

  String get timezone {
    final minutes = DateTime.now().timeZoneOffset.inMinutes;
    final hours = (minutes.abs() ~/ 60).toString().padLeft(2, '0');
    final remainder = (minutes.abs() % 60).toString().padLeft(2, '0');
    return '${minutes < 0 ? '-' : '+'}$hours:$remainder';
  }

  Future<void> pickImage() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_outlined),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
          ],
        ),
      ),
    );
    if (!mounted || source == null) return;
    setState(() => preparing = true);
    try {
      final file = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (file == null || !mounted) return;
      if (await file.length() > 3 * 1024 * 1024) {
        throw const ApiFailure('AI 图片最大为 3 MB，请选择较小的图片');
      }
      final image = await file.readAsBytes();
      if (mounted) setState(() => draftImage = image);
    } catch (failure) {
      if (mounted) message(context, failure);
    } finally {
      if (mounted) setState(() => preparing = false);
    }
  }

  Future<void> dictate() async {
    if (listening) {
      await speech.stop();
      if (mounted) setState(() => listening = false);
      return;
    }
    setState(() => preparing = true);
    try {
      final ready = await prepareDictation(
        speech,
        onStatus: (status) {
          if (mounted && (status == 'done' || status == 'notListening')) {
            setState(() => listening = false);
          }
        },
        onError: (_) {
          if (!mounted) return;
          setState(() => listening = false);
          message(context, '语音识别未完成，请检查麦克风权限后重试');
        },
      );
      if (!ready) throw const ApiFailure('请在系统设置中允许语音识别和麦克风权限');
      final locales = await speech.locales();
      final chinese = locales
          .where(
            (locale) =>
                locale.localeId.replaceAll('-', '_').toLowerCase() == 'zh_cn',
          )
          .firstOrNull;
      if (!mounted) return;
      final old = input.value;
      final start = old.selection.isValid
          ? old.selection.start
          : old.text.length;
      final end = old.selection.isValid ? old.selection.end : old.text.length;
      final prefix = old.text.substring(0, start);
      final suffix = old.text.substring(end);
      await speech.listen(
        listenOptions: SpeechListenOptions(
          localeId: chinese?.localeId,
          listenMode: ListenMode.dictation,
          partialResults: true,
          cancelOnError: true,
        ),
        onResult: (result) {
          if (!mounted || result.recognizedWords.isEmpty) return;
          final words = result.recognizedWords;
          final value = '$prefix$words$suffix';
          if (value.length > 4000) return;
          input.value = TextEditingValue(
            text: value,
            selection: TextSelection.collapsed(
              offset: prefix.length + words.length,
            ),
          );
        },
      );
      if (mounted) setState(() => listening = speech.isListening);
    } catch (failure) {
      if (mounted) message(context, failure);
    } finally {
      if (mounted) setState(() => preparing = false);
    }
  }

  Future<Uint8List> loadImage(int id) async {
    final response = await widget.controller.api.call(
      '/ai/image',
      method: 'GET',
      values: {'id': id},
    );
    return base64Decode(text(fields(response['data'])['image']));
  }

  Future<void> showImage(int id) async {
    final image = loadImage(id);
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: FutureBuilder<Uint8List>(
          future: image,
          builder: (context, snapshot) {
            final bytes = snapshot.data;
            if (bytes != null) {
              return InteractiveViewer(child: Image.memory(bytes));
            }
            return Padding(
              padding: const EdgeInsets.all(24),
              child: snapshot.hasError
                  ? Text(snapshot.error.toString())
                  : const Center(
                      widthFactor: 1,
                      heightFactor: 1,
                      child: CircularProgressIndicator(),
                    ),
            );
          },
        ),
      ),
    );
  }

  Future<void> send({String? retry, int imageTurn = 0}) async {
    final question = (retry ?? input.text).trim();
    final draft = retry == null ? draftImage : null;
    if (busy ||
        pending ||
        preparing ||
        listening ||
        !configured ||
        question.isEmpty && draft == null && imageTurn == 0) {
      return;
    }
    setState(() {
      busy = true;
      error = '';
      if (pendingQuestion != question ||
          pendingImageTurn != imageTurn ||
          !identical(pendingImage, draft)) {
        requestId = newId('turn');
      }
      pendingQuestion = question;
      pendingImage = draft;
      pendingImageTurn = imageTurn;
    });
    try {
      final image = imageTurn == 0 ? draft : await loadImage(imageTurn);
      if (!mounted) return;
      await widget.controller.api.call(
        '/ai/chat',
        timeout: const Duration(seconds: 35),
        values: {
          'thread': thread,
          'request_id': requestId,
          'question': question,
          'timezone': timezone,
          if (image != null) 'image': base64Encode(image),
        },
      );
      if (!mounted) return;
      if (retry == null) {
        input.clear();
        draftImage = null;
      }
      pendingQuestion = requestId = null;
      pendingImage = null;
      pendingImageTurn = 0;
      await refresh(bottom: true);
    } catch (failure) {
      if (mounted) setState(() => error = failure.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> history() async {
    await loadConversations();
    if (!mounted) return;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          children: [
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('新对话'),
              onTap: () => Navigator.pop(context, newId('chat')),
            ),
            for (final row in conversations)
              ListTile(
                title: Text(
                  text(row['question']),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                selected: row['thread'] == thread,
                onTap: () => Navigator.pop(context, text(row['thread'])),
              ),
          ],
        ),
      ),
    );
    if (mounted && chosen != null && chosen != thread) choose(chosen);
  }

  Widget messageList({required List<Widget> children}) {
    // Anchor the latest reply before Flutter measures earlier messages.
    final newestFirst = turns.isNotEmpty;
    return ListView(
      controller: scroll,
      reverse: newestFirst,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      children: newestFirst ? children.reversed.toList() : children,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.controller.account == null) {
      return Center(
        child: FilledButton(
          onPressed: widget.onLogin,
          child: const Text('登录后使用 AI'),
        ),
      );
    }
    if (loading) return const Center(child: CircularProgressIndicator());
    return Column(
      children: [
        ListTile(
          dense: true,
          title: Text(model.isEmpty ? 'AI 对话' : model),
          subtitle: const Text('查询已同步的任务、账单和便签'),
          trailing: IconButton(
            tooltip: '对话历史',
            onPressed: busy || preparing || listening ? null : history,
            icon: const Icon(Icons.history),
          ),
        ),
        if (!configured)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Expanded(child: Text('AI 服务暂不可用')),
                TextButton(
                  onPressed: () => loadConversations(initial: true),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        Expanded(
          child: messageList(
            children: [
              if (turns.isEmpty && configured)
                for (final example in ['本月总支出是多少？', '有哪些任务逾期了？', '帮我汇总最近的便签'])
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: busy ? null : () => send(retry: example),
                      child: Text(example),
                    ),
                  ),
              for (final row in turns) ...[
                Align(
                  alignment: Alignment.centerRight,
                  child: Container(
                    margin: const EdgeInsets.only(top: 12, bottom: 8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (row['has_image'] == true)
                          ActionChip(
                            avatar: const Icon(Icons.image_outlined),
                            label: const Text('图片'),
                            onPressed: () => showImage(integer(row['id'])),
                          ),
                        SelectableText(text(row['question'])),
                      ],
                    ),
                  ),
                ),
                if (row['state'] == 'done')
                  AiAnswer(row, openRecord: widget.openRecord)
                else if (row['state'] == 'failed')
                  Row(
                    children: [
                      Expanded(child: Text(text(row['error']))),
                      TextButton(
                        onPressed: busy || pending
                            ? null
                            : () => send(
                                retry: text(row['question']),
                                imageTurn: row['has_image'] == true
                                    ? integer(row['id'])
                                    : 0,
                              ),
                        child: const Text('重试'),
                      ),
                    ],
                  )
                else
                  Text(
                    row['state'] == 'queued' ? '排队中…' : '正在查询和分析…',
                    style: const TextStyle(color: muted),
                  ),
              ],
              if (error.isNotEmpty)
                Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
        if (draftImage != null)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.memory(
                    draftImage!,
                    width: 64,
                    height: 64,
                    fit: BoxFit.cover,
                  ),
                  IconButton(
                    tooltip: '移除图片',
                    onPressed: busy
                        ? null
                        : () => setState(() => draftImage = null),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
          ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: '添加图片',
                  onPressed: busy || preparing || listening || !configured
                      ? null
                      : pickImage,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                ),
                IconButton(
                  tooltip: listening ? '停止语音输入' : '语音输入',
                  onPressed: busy || preparing || !configured ? null : dictate,
                  icon: Icon(
                    listening ? Icons.stop_circle_outlined : Icons.mic_none,
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: input,
                    minLines: 1,
                    maxLines: 4,
                    readOnly: listening,
                    decoration: const InputDecoration(
                      hintText: '问问 AI',
                      counterText: '',
                    ),
                    maxLength: 4000,
                  ),
                ),
                IconButton(
                  tooltip: '发送',
                  onPressed:
                      busy || pending || preparing || listening || !configured
                      ? null
                      : () => send(),
                  icon: const Icon(Icons.send_outlined),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class AiAnswer extends StatelessWidget {
  const AiAnswer(this.turn, {required this.openRecord, super.key});
  final Fields turn;
  final ValueChanged<Fields> openRecord;

  List<Fields> references() {
    try {
      return objects(jsonDecode(text(turn['refs'])))
          .where(
            (ref) =>
                integer(ref['table']) != Tables.bill ||
                ref['explicit_bill_detail'] == true,
          )
          .toList();
    } on FormatException {
      return [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final refs = references();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MarkdownBody(
          data: text(turn['answer']),
          selectable: true,
          softLineBreak: true,
          imageBuilder: (_, _, alt) => Text(alt ?? '图片'),
        ),
        if (refs.isNotEmpty)
          Wrap(
            spacing: 6,
            children: [
              for (final ref in refs)
                ActionChip(
                  label: Text(
                    text(ref['name']),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onPressed: () => openRecord(ref),
                ),
            ],
          ),
      ],
    );
  }
}
