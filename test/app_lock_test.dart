import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gxtodo/app_lock.dart';
import 'package:gxtodo/controller.dart';
import 'package:gxtodo/home.dart';
import 'package:local_auth/local_auth.dart';
import 'package:material_ui/material_ui.dart';

import 'memory_repository.dart';

class _SystemAuth extends LocalAuthentication {
  _SystemAuth({this.supported = true});
  final bool supported;
  final requests = <Completer<bool>>[];

  @override
  Future<bool> isDeviceSupported() async => supported;

  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<Object>? authMessages,
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    bool persistAcrossBackgrounding = false,
  }) {
    expectSync(biometricOnly, isFalse);
    final request = Completer<bool>();
    requests.add(request);
    return request.future;
  }
}

void main() {
  testWidgets('冷启动遮住内容，取消可重试，后台满十分钟重新验证', (tester) async {
    final repository = MemoryRepository();
    final auth = _SystemAuth();
    var now = DateTime(2026, 11, 28, 12);
    final lock = AppLock(repository, authentication: auth, now: () => now);
    addTearDown(lock.dispose);
    await tester.pumpWidget(
      MaterialApp(home: AppLockGate(lock, const Text('私人内容'))),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(auth.requests, hasLength(1), reason: '${lock.error}, ${lock.busy}');
    expect(await repository.setting(AppLock.setting), '1');
    expect(find.text('私人内容'), findsNothing);
    auth.requests.last.completeError(
      const LocalAuthException(code: LocalAuthExceptionCode.userCanceled),
    );
    await tester.pumpAndSettle();
    expect(find.text('私人内容'), findsNothing);
    await tester.tap(find.text('使用系统验证解锁'));
    auth.requests.last.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('私人内容'), findsOneWidget);

    Future<void> backgroundFor(Duration duration) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      now = now.add(duration);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
    }

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    now = now.add(const Duration(minutes: 11));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(auth.requests, hasLength(2));
    await backgroundFor(const Duration(minutes: 9, seconds: 59));
    expect(find.text('私人内容'), findsOneWidget);
    expect(auth.requests, hasLength(2));

    await backgroundFor(AppLock.timeout);
    expect(auth.requests, hasLength(3));
    expect(find.text('私人内容'), findsNothing);
    await backgroundFor(AppLock.timeout);
    auth.requests.last.complete(true); // 上一次挂起的验证结果不能解锁这次返回。
    await tester.pumpAndSettle();
    expect(
      auth.requests,
      hasLength(4),
      reason: '${lock.covered}, ${lock.error}, ${lock.busy}',
    );
    expect(find.text('私人内容'), findsNothing);
    auth.requests.last.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('私人内容'), findsOneWidget);
  });

  testWidgets('没有系统锁屏时允许进入，仍可从菜单主动开启', (tester) async {
    final auth = _SystemAuth(supported: false);
    final repository = MemoryRepository();
    final lock = AppLock(repository, authentication: auth);
    addTearDown(lock.dispose);
    await tester.pumpWidget(
      MaterialApp(home: AppLockGate(lock, const Text('工作台'))),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('工作台'), findsOneWidget);
    expect(auth.requests, isEmpty);
    final enabling = lock.setEnabled(true);
    auth.requests.last.complete(true);
    await enabling;
    await tester.pumpAndSettle();
    expect(await repository.setting(AppLock.setting), '1');
    expect(lock.enabled, isTrue);
    expect(lock.covered, isFalse);
  });

  testWidgets('侧边菜单关闭应用解锁前必须验证，重开后保留关闭设置', (tester) async {
    final repository = MemoryRepository();
    final controller = TodoController(repository);
    addTearDown(controller.dispose);
    await controller.initialize();
    final auth = _SystemAuth();
    final lock = AppLock(repository, authentication: auth);
    addTearDown(lock.dispose);
    await tester.pumpWidget(TodoApp(controller, appLock: lock));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(auth.requests, hasLength(1), reason: '${lock.error}, ${lock.busy}');
    auth.requests.last.complete(true);
    await tester.pumpAndSettle();
    tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
    await tester.pumpAndSettle();
    final toggle = find.widgetWithText(SwitchListTile, '应用解锁');
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    auth.requests.last.complete(false);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await tester.tap(toggle);
    auth.requests.last.complete(true);
    await tester.pumpAndSettle();
    expect(await repository.setting(AppLock.setting), '0');
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);

    final next = _SystemAuth();
    final reopened = AppLock(repository, authentication: next);
    addTearDown(reopened.dispose);
    await tester.pump();
    expect(next.requests, isEmpty);
    expect(reopened.covered, isFalse);
  });
}
