import 'package:flutter_test/flutter_test.dart';
import 'package:gxtodo/api.dart';
import 'package:gxtodo/domain.dart';
import 'package:gxtodo/sync.dart';

import 'memory_repository.dart';

void main() {
  const origin = String.fromEnvironment('GXTODO_TEST_SERVER');
  test('两个 Flutter 客户端通过自建服务同步中文任务、修改和删除', () async {
    final email = '${newId('test')}@example.net';
    final one = await signIn(
      origin,
      email,
      'Example1234',
      newId('device'),
      true,
    );
    final two = await signIn(
      origin,
      email,
      'Example1234',
      newId('device'),
      false,
    );
    final left = MemoryRepository(), right = MemoryRepository();
    final who = one.account.identity;
    final id = newId(Tables.task);
    await left.change(
      who.scope,
      (value) => value.save(who, who.personal, Tables.task, id, {
        'name': '联调任务',
        'privacy': 6720,
      }),
    );
    await synchronize(left, one.account);
    await synchronize(right, two.account);
    expect(
      (await right.read(who.scope)).get(who.personal, Tables.task, id)?.name,
      '联调任务',
    );
    await right.change(
      who.scope,
      (value) =>
          value.save(who, who.personal, Tables.task, id, {'name': '另一台设备已修改'}),
    );
    await synchronize(right, two.account);
    await synchronize(left, one.account);
    expect(
      (await left.read(who.scope)).get(who.personal, Tables.task, id)?.name,
      '另一台设备已修改',
    );
    await left.change(
      who.scope,
      (value) => value.remove(value.get(who.personal, Tables.task, id)),
    );
    await synchronize(left, one.account);
    await synchronize(right, two.account);
    expect(
      (await right.read(who.scope)).get(who.personal, Tables.task, id),
      isNull,
    );
  }, skip: origin.isEmpty ? '需要显式指定测试服务器' : false);
}
