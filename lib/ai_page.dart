import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'appearance.dart';
import 'controller.dart';
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
  final scroll = ScrollController();
  var thread = newId('chat');
  List<Fields> turns = [];
  List<Fields> conversations = [];
  String error = '', model = '';
  bool loading = true, busy = false, configured = false, fetching = false;
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
    if (scroll.hasClients) scroll.jumpTo(scroll.position.maxScrollExtent);
  });

  void choose(String value) {
    timer?.cancel();
    setState(() {
      thread = value;
      turns = [];
      error = '';
      pendingQuestion = requestId = null;
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

  Future<void> send([String? retry]) async {
    final question = (retry ?? input.text).trim();
    if (busy || pending || !configured || question.isEmpty) return;
    setState(() {
      busy = true;
      error = '';
      if (pendingQuestion != question) requestId = newId('turn');
      pendingQuestion = question;
    });
    try {
      await widget.controller.api.call(
        '/ai/chat',
        values: {
          'thread': thread,
          'request_id': requestId,
          'question': question,
          'timezone': timezone,
        },
      );
      if (!mounted) return;
      input.clear();
      pendingQuestion = requestId = null;
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

  List<Fields> refs(Fields row) {
    try {
      return objects(jsonDecode(text(row['refs']))).toList();
    } on FormatException {
      return [];
    }
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
            onPressed: busy ? null : history,
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
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            children: [
              if (turns.isEmpty && configured)
                for (final example in ['本月总支出是多少？', '有哪些任务逾期了？', '帮我汇总最近的便签'])
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: busy ? null : () => send(example),
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
                    child: SelectableText(text(row['question'])),
                  ),
                ),
                if (row['state'] == 'done') ...[
                  SelectableText(text(row['answer'])),
                  if (refs(row).isNotEmpty)
                    Wrap(
                      spacing: 6,
                      children: [
                        for (final ref in refs(row))
                          ActionChip(
                            label: Text(
                              text(ref['name']),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onPressed: () => widget.openRecord(ref),
                          ),
                      ],
                    ),
                ] else if (row['state'] == 'failed')
                  Row(
                    children: [
                      Expanded(child: Text(text(row['error']))),
                      TextButton(
                        onPressed: busy || pending
                            ? null
                            : () => send(text(row['question'])),
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
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: input,
                    minLines: 1,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: '问问 AI',
                      counterText: '',
                    ),
                    maxLength: 4000,
                  ),
                ),
                IconButton(
                  tooltip: '发送',
                  onPressed: busy || pending || !configured ? null : send,
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
