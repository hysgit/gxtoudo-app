import 'dart:async';

import 'package:local_auth/local_auth.dart';
import 'package:material_ui/material_ui.dart';

import 'repository.dart';

class AppLock extends ChangeNotifier with WidgetsBindingObserver {
  AppLock(
    this.repository, {
    LocalAuthentication? authentication,
    DateTime Function()? now,
  }) : _auth = authentication ?? LocalAuthentication(),
       _now = now ?? DateTime.now {
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  static const setting = 'app_lock_enabled';
  static const timeout = Duration(minutes: 10);
  final LocalRepository repository;
  final LocalAuthentication _auth;
  final DateTime Function() _now;
  bool? _enabled;
  bool _locked = true, _pending = false, _busy = false, _disposed = false;
  DateTime? _backgroundSince;
  int _generation = 0;
  String? error;

  bool get enabled => _enabled == true;
  bool get busy => _busy;
  bool get _active =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  bool get covered => _enabled == null || (enabled && (_locked || !_active));

  Future<void> _load() async {
    _busy = true;
    error = null;
    notifyListeners();
    try {
      final saved = await repository.setting(setting);
      final useLock = saved == null
          ? await _auth.isDeviceSupported()
          : saved != '0';
      if (saved == null && useLock) await repository.setSetting(setting, '1');
      _enabled = useLock;
      _locked = _pending = useLock;
    } catch (_) {
      error = '无法读取应用解锁设置，请重试。';
    } finally {
      _finish();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _backgroundSince ??= _now();
      case AppLifecycleState.resumed:
        final since = _backgroundSince;
        _backgroundSince = null;
        if (enabled && since != null) {
          final elapsed = _now().difference(since);
          if (elapsed >= timeout || elapsed.isNegative) {
            _locked = _pending = true;
            _generation++;
          }
        }
      case AppLifecycleState.inactive:
        break;
    }
    notifyListeners();
    _promptIfNeeded();
  }

  void _promptIfNeeded() {
    if (_pending && _active && !_busy) unawaited(unlock());
  }

  void _finish() {
    _busy = false;
    if (_disposed) return;
    notifyListeners();
    _promptIfNeeded();
  }

  Future<bool> _verify(String reason) =>
      _auth.authenticate(localizedReason: reason, sensitiveTransaction: false);

  String? _authFailure(LocalAuthException error) => switch (error.code) {
    LocalAuthExceptionCode.userCanceled ||
    LocalAuthExceptionCode.systemCanceled => null,
    LocalAuthExceptionCode.noCredentialsSet ||
    LocalAuthExceptionCode.noBiometricsEnrolled => '请先在手机系统设置中启用锁屏验证。',
    _ => '暂时无法完成系统验证，请重试。',
  };

  Future<void> unlock() async {
    if (_busy || !_active) return;
    if (_enabled == null) {
      await _load();
      return;
    }
    if (!enabled || !_locked) return;
    _pending = false;
    _busy = true;
    error = null;
    final generation = _generation;
    notifyListeners();
    try {
      if (await _verify('请验证身份以解锁高效Todo') && generation == _generation) {
        _locked = false;
      }
    } on LocalAuthException catch (failure) {
      error = _authFailure(failure);
    } catch (_) {
      error = '暂时无法完成系统验证，请重试。';
    } finally {
      _finish();
    }
  }

  Future<String?> setEnabled(bool value) async {
    if (_busy || covered || !_active || value == enabled) return null;
    _busy = true;
    final generation = _generation;
    notifyListeners();
    try {
      final verified = await _verify(value ? '请验证身份以开启应用解锁' : '请验证身份以关闭应用解锁');
      if (!verified || generation != _generation || _disposed) return null;
      await repository.setSetting(setting, value ? '1' : '0');
      _enabled = value;
      return null;
    } on LocalAuthException catch (failure) {
      return _authFailure(failure);
    } catch (_) {
      return '无法保存应用解锁设置，请重试。';
    } finally {
      _finish();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class AppLockGate extends StatelessWidget {
  const AppLockGate(this.lock, this.child, {super.key});

  final AppLock lock;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: lock,
    child: child,
    builder: (context, child) => Stack(
      fit: StackFit.expand,
      children: [
        Offstage(
          offstage: lock.covered,
          child: ExcludeFocus(excluding: lock.covered, child: child!),
        ),
        if (lock.covered)
          Scaffold(
            body: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.lock_outline,
                        size: 40,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 14),
                      Text(
                        '高效Todo 已锁定',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      if (lock.error case final error?) ...[
                        const SizedBox(height: 8),
                        Text(error, textAlign: TextAlign.center),
                      ],
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: lock.busy ? null : lock.unlock,
                        child: Text(lock.busy ? '正在验证…' : '使用系统验证解锁'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
