import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'api.dart';
import 'appearance.dart';
import 'controller.dart';
import 'domain.dart';

class DesktopLoginPage extends StatefulWidget {
  const DesktopLoginPage(
    this.controller, {
    required this.chooseServer,
    super.key,
  });
  final TodoController controller;
  final Future<String?> Function(BuildContext) chooseServer;

  @override
  State<DesktopLoginPage> createState() => _DesktopLoginPageState();
}

class _DesktopLoginPageState extends State<DesktopLoginPage> {
  final random = Random.secure();
  Timer? nextPoll;
  int generation = 0;
  Uri? qr;
  String code = '', error = '';
  bool loading = false;

  List<int> randomBytes(int length) =>
      List<int>.generate(length, (_) => random.nextInt(256));

  @override
  void initState() {
    super.initState();
    unawaited(start());
  }

  @override
  void dispose() {
    nextPoll?.cancel();
    super.dispose();
  }

  Future<void> start() async {
    final current = ++generation;
    nextPoll?.cancel();
    final controller = widget.controller;
    final server = controller.server;
    setState(() {
      loading = true;
      qr = null;
      error = '';
    });
    try {
      final saved = await controller.repository.setting('desktop_device');
      final device =
          saved ??
          'desktop-${randomBytes(16).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}';
      if (saved == null) {
        await controller.repository.setSetting('desktop_device', device);
      }
      final verifier = base64UrlEncode(randomBytes(32)).replaceAll('=', '');
      final reply = await TodoApi(server).call(
        '/desktop-login/start',
        values: {
          'challenge': sha256.convert(utf8.encode(verifier)).toString(),
          'dev_id': device,
          'label': 'Windows 桌面端',
        },
      );
      if (!mounted || current != generation) return;
      final request = text(reply['request']);
      final validity = integer(reply['valid_seconds']);
      if (request.isEmpty || validity <= 0) {
        throw const ApiFailure('没有收到有效的登录二维码');
      }
      final expires = DateTime.now().add(Duration(seconds: validity));
      setState(() {
        qr = Uri(
          scheme: 'gxtodo',
          host: 'desktop-login',
          queryParameters: {'server': server, 'request': request},
        );
        code = text(reply['code']);
        loading = false;
      });
      unawaited(poll(current, server, request, verifier, expires));
    } catch (failure) {
      if (!mounted || current != generation) return;
      setState(() {
        loading = false;
        error = failure.toString();
      });
    }
  }

  Future<void> poll(
    int current,
    String server,
    String request,
    String verifier,
    DateTime expires,
  ) async {
    if (!mounted || current != generation) return;
    if (!DateTime.now().isBefore(expires)) {
      setState(() {
        qr = null;
        error = '二维码已过期，请刷新';
      });
      return;
    }
    try {
      final result = await TodoApi(server).call(
        '/desktop-login/poll',
        values: {'request': request, 'verifier': verifier},
        timeout: const Duration(seconds: 8),
      );
      if (!mounted || current != generation) return;
      if (result['state'] == 'complete') {
        setState(() => loading = true);
        await widget.controller.acceptDesktopLogin(server, result);
        return;
      }
      if (error.isNotEmpty) setState(() => error = '');
    } catch (failure) {
      if (!mounted || current != generation) return;
      setState(() {
        loading = false;
        error = failure.toString();
        if (failure is ApiFailure && failure.status == '410') qr = null;
      });
      if (qr == null) return;
    }
    nextPoll = Timer(const Duration(seconds: 2), () {
      unawaited(poll(current, server, request, verifier, expires));
    });
  }

  Future<void> changeServer() async {
    final desired = await widget.chooseServer(context);
    if (!mounted || desired == null || loading) return;
    generation++;
    nextPoll?.cancel();
    setState(() => loading = true);
    try {
      await widget.controller.changeServer(desired);
      if (mounted && widget.controller.account == null) await start();
    } catch (failure) {
      if (mounted) {
        message(context, failure);
        await start();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ui = Theme.of(context);
    final image = qr;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('高效 Todo', style: ui.textTheme.headlineMedium),
                      const SizedBox(height: 8),
                      const Text('在手机端打开「账户与服务端」→「扫码登录桌面端」'),
                      const SizedBox(height: 20),
                      if (image != null) ...[
                        QrImageView(
                          data: image.toString(),
                          size: 248,
                          backgroundColor: Colors.white,
                        ),
                        const SizedBox(height: 12),
                        Text('核对码  $code', style: ui.textTheme.titleMedium),
                      ] else if (loading)
                        const CircularProgressIndicator(),
                      if (error.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(
                          error,
                          style: TextStyle(color: ui.colorScheme.error),
                        ),
                      ],
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: loading ? null : start,
                        child: const Text('刷新二维码'),
                      ),
                      TextButton.icon(
                        onPressed: loading ? null : changeServer,
                        icon: const Icon(Icons.dns_outlined, size: 18),
                        label: Text(
                          Uri.tryParse(widget.controller.server)?.host ??
                              '设置服务端',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> scanDesktopLogin(
  BuildContext context,
  TodoController controller,
) async {
  final account = controller.account;
  if (account == null) return;
  final raw = await Navigator.push<String>(
    context,
    MaterialPageRoute(builder: (_) => const _DesktopScanner()),
  );
  if (!context.mounted || raw == null || controller.account != account) return;
  try {
    final uri = Uri.parse(raw);
    final request = uri.queryParameters['request'];
    if (uri.scheme != 'gxtodo' ||
        uri.host != 'desktop-login' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.path.isNotEmpty ||
        uri.hasFragment ||
        request == null ||
        request.isEmpty ||
        uri.queryParameters['server'] != account.server) {
      throw const ApiFailure('请扫描同一服务端的高效 Todo 桌面登录码');
    }
    final api = TodoApi(account.server, account);
    final reply = await api.call(
      '/desktop-login/preview',
      values: {'request': request},
    );
    if (!context.mounted || controller.account != account) return;
    final allowed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('确认登录桌面端'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(text(reply['label'])),
            const SizedBox(height: 12),
            Text('请核对电脑上的号码  ${text(reply['code'])}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('确认登录'),
          ),
        ],
      ),
    );
    if (allowed != true || !context.mounted || controller.account != account) {
      return;
    }
    await api.call('/desktop-login/approve', values: {'request': request});
    if (context.mounted) message(context, '已确认，请在电脑上查看');
  } catch (failure) {
    if (context.mounted) message(context, failure);
  }
}

class _DesktopScanner extends StatefulWidget {
  const _DesktopScanner();

  @override
  State<_DesktopScanner> createState() => _DesktopScannerState();
}

class _DesktopScannerState extends State<_DesktopScanner> {
  final scanner = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  bool captured = false;

  @override
  void dispose() {
    unawaited(scanner.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('扫描桌面登录码')),
    body: MobileScanner(
      controller: scanner,
      errorBuilder: (context, error) =>
          const Center(child: Text('无法打开相机，请检查系统相机权限')),
      onDetect: (result) {
        if (captured || !mounted) return;
        final raw = result.barcodes
            .map((barcode) => barcode.rawValue)
            .whereType<String>()
            .firstOrNull;
        if (raw == null) return;
        captured = true;
        Navigator.pop(context, raw);
      },
    ),
  );
}
