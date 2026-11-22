import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'domain.dart';
import 'repository.dart';
import 'sync.dart';

class TodoController extends ChangeNotifier {
  TodoController(this.repository, {this.automatic = true, this.onLocalChange});
  final LocalRepository repository;
  final bool automatic;
  final Future<void> Function()? onLocalChange;
  Future<void> Function(Account)? onLogout;
  WorkspaceData data = WorkspaceData();
  Account? account;
  String server = defaultServer;
  int team = -1;
  bool ready = false;
  Future<int>? _inFlight;
  String? _syncToken;
  bool get syncing => _inFlight != null;
  String syncStatus = '';
  String? initializationError;
  Timer? _scheduledSync;
  bool _disposed = false;
  int _dataVersion = 0;
  int _retrySeconds = 10;

  Identity get identity => account?.identity ?? Identity.guest;
  TodoApi get api => TodoApi(server, account);
  List<Space> get spaces => account == null ? [Space.guest] : data.spaces;
  Space get space =>
      spaces.where((space) => space.id == team).firstOrNull ??
      Space(identity.personal, '个人空间', 1, identity.user);

  Future<void> initialize() async {
    try {
      server = await repository.setting('server') ?? defaultServer;
      final stored = await repository.setting('account');
      if (stored != null) {
        final existing = Account.fromJson(fields(jsonDecode(stored)));
        if (existing.server == server &&
            existing.personal > 0 &&
            existing.token.isNotEmpty) {
          account = existing;
        }
      }
      team = identity.personal;
      data = await repository.read(identity.scope);
      ready = true;
    } catch (error) {
      initializationError = error.toString();
    }
    _notify();
    _queueSync();
  }

  Future<void> mutate(void Function(WorkspaceData, Identity) action) async {
    final who = identity;
    final changed = await repository.change(
      who.scope,
      (data) => action(data, who),
    );
    if (identity.scope == who.scope) {
      _dataVersion++;
      data = changed;
      _notify();
      _queueSync();
      if (account != null && onLocalChange != null) {
        unawaited(
          onLocalChange!().catchError((Object error) {
            debugPrint('Background sync scheduling failed: $error');
          }),
        );
      }
    }
  }

  void selectSpace(int value) {
    team = value;
    _notify();
  }

  Future<void> changeServer(String value) async {
    final origin = serverOrigin(value);
    if (server == origin) return;
    await logout();
    await repository.setSetting('server', origin);
    server = origin;
    _notify();
  }

  Future<void> login(
    String email,
    String password, {
    required bool register,
  }) async {
    final origin = server;
    final device = await repository.setting('device') ?? newId('device');
    await repository.setSetting('device', device);
    final result = await signIn(
      origin,
      email.trim(),
      password,
      device,
      register,
    );
    if (server != origin) throw const ApiFailure('服务端地址已变化，请重新登录');
    final updated = await repository.change(
      result.account.identity.scope,
      (data) => data.spaces = result.spaces,
    );
    await repository.setSetting('account', jsonEncode(result.account.toJson()));
    account = result.account;
    team = identity.personal;
    data = updated;
    _notify();
    _queueSync();
  }

  Future<void> updateProfile(Fields changes) async {
    final snapshot = account;
    if (snapshot == null) throw const ApiFailure('请先登录');
    final result = await api.call(
      '/user/base',
      method: 'PUT',
      values: {'_data': changes},
    );
    if (account != snapshot) return;
    final revised = snapshot.withProfile(fields(result['data']));
    await repository.setSetting('account', jsonEncode(revised.toJson()));
    account = revised;
    _notify();
  }

  Future<void> logout() async {
    _scheduledSync?.cancel();
    final previous = account;
    if (previous != null) await onLogout?.call(previous);
    await repository.setSetting('account', null);
    account = null;
    data = await repository.read(Identity.guest.scope);
    team = identity.personal;
    syncStatus = '';
    _notify();
  }

  Future<int> sync() async {
    final snapshot = account;
    if (snapshot == null) return 0;
    final active = _inFlight;
    if (active != null) {
      if (_syncToken == snapshot.token) return active;
      try {
        await active;
      } catch (_) {
        // A previous account's request can fail without blocking the current account.
      }
      return account?.token == snapshot.token ? sync() : 0;
    }
    _syncToken = snapshot.token;
    final scheduled = Future<int>(() => _sync(snapshot));
    _inFlight = scheduled;
    return scheduled;
  }

  Future<int> _sync(Account snapshot) async {
    syncStatus = '正在同步';
    _notify();
    try {
      final count = await synchronize(
        repository,
        snapshot,
        onChanged: () => _refresh(snapshot),
      );
      if (account?.token == snapshot.token) {
        if (!spaces.any((space) => space.id == team)) {
          team = snapshot.personal;
        }
        syncStatus = '同步完成';
        _retrySeconds = 10;
      }
      return count;
    } catch (error) {
      if (account?.token == snapshot.token) syncStatus = '同步失败 · $error';
      _retrySeconds = (_retrySeconds * 2).clamp(10, 300);
      rethrow;
    } finally {
      _inFlight = null;
      _syncToken = null;
      await _refresh(snapshot);
      _notify();
      _queueSync(
        delay:
            syncStatus == '同步完成' &&
                data.items.values.any((row) => row.pending != 0)
            ? const Duration(milliseconds: 1250)
            : Duration(seconds: syncStatus == '同步完成' ? 45 : _retrySeconds),
      );
    }
  }

  Future<void> _refresh(Account snapshot) async {
    final version = _dataVersion;
    final latest = await repository.read(snapshot.identity.scope);
    if (account?.token != snapshot.token || version != _dataVersion) return;
    _dataVersion++;
    data = latest;
    _notify();
  }

  Future<void> resume() async {
    final signedIn = account;
    if (signedIn != null) await _refresh(signedIn);
    _queueSync();
  }

  void _queueSync({Duration delay = const Duration(milliseconds: 1250)}) {
    if (account == null || _disposed || !automatic) return;
    _scheduledSync?.cancel();
    _scheduledSync = Timer(delay, () async {
      if (syncing) {
        _queueSync();
        return;
      }
      try {
        await sync();
      } catch (_) {
        // The message is shown in the account menu and manual sync action.
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _scheduledSync?.cancel();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}
