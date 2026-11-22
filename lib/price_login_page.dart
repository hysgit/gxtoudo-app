import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import 'api.dart';
import 'appearance.dart';
import 'domain.dart';

class PriceLoginPage extends StatefulWidget {
  const PriceLoginPage(this.api, this.platform, {super.key});
  final TodoApi api;
  final String platform;
  String get name => platform == 'jd' ? '京东' : '淘宝';

  @override
  State<PriceLoginPage> createState() => _PriceLoginPageState();
}

class _PriceLoginPageState extends State<PriceLoginPage> {
  String session = '', host = '', error = '';
  Uint8List? frame;
  int width = 390, height = 760;
  bool busy = false, typing = false, canSave = false, userAction = false;
  Timer? timer;
  Offset dragStart = Offset.zero, dragEnd = Offset.zero;

  @override
  void initState() {
    super.initState();
    unawaited(command('start'));
    timer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (session.isNotEmpty && !typing && error.isEmpty) {
        unawaited(command('frame'));
      }
    });
  }

  Future<Fields> send(String action, String id, Fields values) =>
      widget.api.call(
        '/price/login',
        timeout: const Duration(seconds: 29),
        values: {
          ...values,
          'platform': widget.platform,
          'action': action,
          if (id.isNotEmpty) 'session': id,
        },
      );

  Future<void> command(String action, [Fields values = const {}]) async {
    if (busy || (action != 'start' && session.isEmpty)) return;
    busy = true;
    if (action != 'frame') setState(() => userAction = true);
    try {
      final result = fields((await send(action, session, values))['data']);
      if (!mounted) {
        final abandoned = text(result['session']);
        if (action == 'start' && abandoned.isNotEmpty) {
          unawaited(
            send(
              'cancel',
              abandoned,
              {},
            ).catchError((Object _) => <String, dynamic>{}),
          );
        }
        return;
      }
      if (action == 'finish') {
        session = '';
        Navigator.pop(context, integer(result['saved_at']));
        return;
      }
      final bytes = base64Decode(text(result['image']));
      setState(() {
        session = text(result['session']);
        host = text(result['host']);
        canSave = result['can_save'] == true;
        frame = bytes;
        width = integer(result['width'], 390);
        height = integer(result['height'], 760);
        error = '';
      });
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        error = failure.toString();
        if (failure is ApiFailure && failure.status == '410') {
          session = '';
          frame = null;
          canSave = false;
        }
      });
    } finally {
      busy = false;
      if (mounted && userAction) setState(() => userAction = false);
    }
  }

  Future<void> enter() async {
    if (busy || typing || session.isEmpty) return;
    typing = true;
    try {
      final value = await showDialog<String>(
        context: context,
        builder: (_) => const _BrowserInput(),
      );
      if (mounted && value != null && value.isNotEmpty) {
        await command('type', {'input': value});
      }
    } finally {
      typing = false;
    }
  }

  void retry() => unawaited(command(session.isEmpty ? 'start' : 'frame'));

  @override
  void dispose() {
    timer?.cancel();
    if (session.isNotEmpty) {
      unawaited(
        send(
          'cancel',
          session,
          {},
        ).catchError((Object _) => <String, dynamic>{}),
      );
    }
    super.dispose();
  }

  Widget browser() => LayoutBuilder(
    builder: (context, constraints) {
      final ratio = width / height;
      final size = constraints.maxWidth / ratio <= constraints.maxHeight
          ? Size(constraints.maxWidth, constraints.maxWidth / ratio)
          : Size(constraints.maxHeight * ratio, constraints.maxHeight);
      if (size.isEmpty) return const SizedBox.shrink();
      Fields point(Offset position) => {
        'x': (position.dx * width / size.width).floor().clamp(0, width - 1),
        'y': (position.dy * height / size.height).floor().clamp(0, height - 1),
      };
      return Center(
        child: GestureDetector(
          onTapUp: (detail) => command('tap', point(detail.localPosition)),
          onPanDown: (detail) => dragStart = dragEnd = detail.localPosition,
          onPanUpdate: (detail) => dragEnd = detail.localPosition,
          onPanEnd: (_) {
            final delta = dragEnd - dragStart;
            if (delta.dx.abs() > delta.dy.abs() && delta.dx.abs() >= 8) {
              final from = point(dragStart), to = point(dragEnd);
              unawaited(
                command('drag', {
                  'from_x': from['x'],
                  'from_y': from['y'],
                  'to_x': to['x'],
                  'to_y': to['y'],
                }),
              );
            } else if (delta.dy.abs() >= 8) {
              unawaited(
                command('scroll', {
                  ...point(dragStart),
                  'dy': (-delta.dy * height / size.height).round().clamp(
                    -850,
                    850,
                  ),
                }),
              );
            }
          },
          child: Image.memory(
            frame!,
            width: size.width,
            height: size.height,
            fit: BoxFit.fill,
            gaplessPlayback: true,
            semanticLabel: '可操作的${widget.name}官方网页',
          ),
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('${widget.name}登录'),
      actions: [
        TextButton(
          onPressed: userAction || !canSave ? null : () => command('finish'),
          child: const Text('保存会话'),
        ),
      ],
    ),
    body: SafeArea(
      top: false,
      child: Column(
        children: [
          if (host.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  const Icon(Icons.lock_outline, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(host, style: const TextStyle(color: muted)),
                  ),
                  IconButton(
                    tooltip: '重开平台登录页',
                    onPressed: userAction ? null : () => command('reset'),
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ),
          if (error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Expanded(child: Text(error)),
                  TextButton(
                    onPressed: userAction ? null : retry,
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: frame != null
                ? browser()
                : Center(
                    child: userAction
                        ? const CircularProgressIndicator()
                        : const Text('等待平台网页打开'),
                  ),
          ),
          if (frame != null) ...[
            if (userAction) const LinearProgressIndicator(minHeight: 2),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  TextButton.icon(
                    onPressed: userAction ? null : enter,
                    icon: const Icon(Icons.keyboard_outlined),
                    label: const Text('输入'),
                  ),
                  IconButton(
                    tooltip: '删除一个字符',
                    onPressed: userAction
                        ? null
                        : () => command('key', {'key': 'Backspace'}),
                    icon: const Icon(Icons.backspace_outlined),
                  ),
                  IconButton(
                    tooltip: '回车',
                    onPressed: userAction
                        ? null
                        : () => command('key', {'key': 'Enter'}),
                    icon: const Icon(Icons.keyboard_return),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

class _BrowserInput extends StatefulWidget {
  const _BrowserInput();
  @override
  State<_BrowserInput> createState() => _BrowserInputState();
}

class _BrowserInputState extends State<_BrowserInput> {
  final controller = TextEditingController();
  @override
  void dispose() {
    controller.clear();
    controller.dispose();
    super.dispose();
  }

  void submit() => Navigator.pop(context, controller.text);

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('输入到当前网页字段'),
    content: TextField(
      controller: controller,
      autofocus: true,
      obscureText: true,
      maxLength: 512,
      autocorrect: false,
      enableSuggestions: false,
      decoration: const InputDecoration(
        hintText: '手机号、密码或验证码',
        counterText: '',
      ),
      onSubmitted: (_) => submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: submit, child: const Text('填入网页')),
    ],
  );
}
