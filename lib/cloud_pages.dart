import 'package:material_ui/material_ui.dart';

import 'appearance.dart';
import 'controller.dart';
import 'domain.dart';
import 'tasks.dart';

Future<String?> askText(
  BuildContext context,
  String title,
  String label, {
  String initial = '',
  int limit = 100,
}) async {
  var value = initial;
  return showDialog<String>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(title),
      content: TextFormField(
        initialValue: initial,
        maxLength: limit,
        decoration: InputDecoration(labelText: label),
        onChanged: (updated) => value = updated,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            if (value.trim().isNotEmpty) Navigator.pop(dialog, value.trim());
          },
          child: const Text('保存'),
        ),
      ],
    ),
  );
}

class AccountPage extends StatefulWidget {
  const AccountPage(this.controller, {super.key});
  final TodoController controller;

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final email = TextEditingController();
  final password = TextEditingController();
  bool busy = false;
  bool register = false;
  String error = '';

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> perform(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await action();
    } catch (failure) {
      if (mounted) setState(() => error = failure.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final account = controller.account;
        return Scaffold(
          appBar: AppBar(title: const Text('账户与服务端')),
          body: PageContent(
            children: [
              Card(
                child: ListTile(
                  leading: const Icon(Icons.cloud_outlined),
                  title: const Text('服务端地址'),
                  subtitle: Text(
                    controller.server.isEmpty ? '未设置' : controller.server,
                  ),
                  trailing: const Icon(Icons.edit_outlined),
                  onTap: busy
                      ? null
                      : () async {
                          final value = await askText(
                            context,
                            '设置服务端',
                            'HTTPS 地址',
                            initial: controller.server,
                            limit: 255,
                          );
                          if (value != null && mounted) {
                            await perform(() => controller.changeServer(value));
                          }
                        },
                ),
              ),
              const SizedBox(height: 16),
              if (error.isNotEmpty) ...[
                Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                const SizedBox(height: 12),
              ],
              if (account == null) ...[
                Text(
                  register ? '注册账号' : '登录账号',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: email,
                  decoration: const InputDecoration(labelText: '邮箱'),
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: password,
                  decoration: const InputDecoration(labelText: '密码'),
                  obscureText: true,
                  autofillHints: [
                    register
                        ? AutofillHints.newPassword
                        : AutofillHints.password,
                  ],
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: busy
                      ? null
                      : () => perform(() async {
                          await controller.login(
                            email.text,
                            password.text,
                            register: register,
                          );
                          password.clear();
                        }),
                  child: Text(
                    busy
                        ? '处理中'
                        : register
                        ? '注册并登录'
                        : '登录',
                  ),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => setState(() {
                          register = !register;
                          error = '';
                        }),
                  child: Text(register ? '返回登录' : '创建账号'),
                ),
                if (!register)
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => perform(() async {
                            if (email.text.trim().isEmpty) {
                              throw const FormatException('请先输入邮箱');
                            }
                            await controller.api.call(
                              '/user/mail',
                              values: {'email': email.text.trim()},
                            );
                            if (context.mounted) {
                              message(context, '如该邮箱已注册，请检查收件箱');
                            }
                          }),
                    child: const Text('找回密码'),
                  ),
              ] else ...[
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: Text(account.nickname),
                    subtitle: Text(account.email),
                    trailing: const Icon(Icons.edit_outlined),
                    onTap: busy
                        ? null
                        : () async {
                            final name = await askText(
                              context,
                              '编辑昵称',
                              '昵称',
                              initial: account.nickname,
                              limit: 64,
                            );
                            if (name != null && mounted) {
                              await perform(
                                () => controller.updateProfile({
                                  'nickname': name,
                                }),
                              );
                            }
                          },
                  ),
                ),
                if (controller.syncStatus.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(controller.syncStatus),
                  ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.sync),
                  label: const Text('立即同步'),
                  onPressed: busy || controller.syncing
                      ? null
                      : () => perform(() async {
                          final count = await controller.sync();
                          if (context.mounted) {
                            message(context, '同步完成 · $count 条本机改动');
                          }
                        }),
                ),
                OutlinedButton(
                  onPressed: busy
                      ? null
                      : () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PasswordPage(controller),
                          ),
                        ),
                  child: const Text('修改密码'),
                ),
                TextButton(
                  onPressed: busy ? null : () => perform(controller.logout),
                  child: const Text('退出登录'),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () async {
                          final accepted = await confirm(
                            context,
                            '注销账号？',
                            '此操作会停用账号，并使所有设备退出登录。',
                          );
                          if (!accepted || !context.mounted) return;
                          await perform(() async {
                            await controller.api.call(
                              '/user/deactivate',
                              method: 'PUT',
                            );
                            await controller.logout();
                          });
                        },
                  child: Text(
                    '注销账号',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class PasswordPage extends StatefulWidget {
  const PasswordPage(this.controller, {super.key});
  final TodoController controller;

  @override
  State<PasswordPage> createState() => _PasswordPageState();
}

class _PasswordPageState extends State<PasswordPage> {
  String old = '', password = '';
  bool busy = false;

  Future<void> save() async {
    if (old.isEmpty || password.length < 6) {
      message(context, '请输入当前密码和至少 6 位的新密码');
      return;
    }
    setState(() => busy = true);
    try {
      await widget.controller.updateProfile({
        'password0': old,
        'password': password,
      });
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) message(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('修改密码')),
    body: PageContent(
      children: [
        TextFormField(
          obscureText: true,
          decoration: const InputDecoration(labelText: '当前密码'),
          onChanged: (value) => old = value,
        ),
        const SizedBox(height: 12),
        TextFormField(
          obscureText: true,
          decoration: const InputDecoration(labelText: '新密码'),
          onChanged: (value) => password = value,
        ),
        const SizedBox(height: 12),
        FilledButton(onPressed: busy ? null : save, child: const Text('保存')),
      ],
    ),
  );
}

class TeamsPage extends StatefulWidget {
  const TeamsPage(this.controller, {super.key});
  final TodoController controller;

  @override
  State<TeamsPage> createState() => _TeamsPageState();
}

class _TeamsPageState extends State<TeamsPage> {
  List<Space>? results;
  var loading = false;
  var query = '';
  var searchId = 0;

  Future<void> search() async {
    final request = ++searchId;
    if (query.trim().isEmpty) {
      setState(() {
        results = null;
        loading = false;
      });
      return;
    }
    setState(() => loading = true);
    try {
      final reply = await widget.controller.api.call(
        '/team/list',
        values: {'keyword': query.trim()},
      );
      if (mounted && request == searchId) {
        setState(
          () => results = objects(reply['data']).map(Space.fromJson).toList(),
        );
      }
    } catch (error) {
      if (mounted && request == searchId) message(context, error);
    } finally {
      if (mounted && request == searchId) setState(() => loading = false);
    }
  }

  Future<void> requestJoin(Space team) async {
    try {
      await widget.controller.api.call(
        '/message/base',
        values: {
          'type': 1,
          'event': 11,
          'recipient': team.owner,
          '_data': {'id': team.id, 'name': team.name, 'operate': 0},
        },
      );
      if (mounted) message(context, '加入申请已提交');
    } catch (error) {
      if (mounted) message(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final teams =
            results ??
            controller.spaces.where((team) => team.type != 1).toList();
        return Scaffold(
          appBar: AppBar(
            title: const Text('团队空间'),
            actions: [
              IconButton(
                tooltip: '新建团队',
                icon: const Icon(Icons.group_add_outlined),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => TeamEditor(controller)),
                ),
              ),
            ],
          ),
          body: PageContent(
            children: [
              TextFormField(
                decoration: InputDecoration(
                  labelText: '搜索团队名称或编号',
                  suffixIcon: IconButton(
                    tooltip: '搜索团队',
                    icon: const Icon(Icons.search),
                    onPressed: search,
                  ),
                ),
                textInputAction: TextInputAction.search,
                onChanged: (value) => query = value,
                onFieldSubmitted: (_) => search(),
              ),
              const SizedBox(height: 12),
              if (loading) const LinearProgressIndicator(),
              if (!loading && teams.isEmpty)
                EmptyContent(
                  results == null ? '还没有加入团队' : '没有找到团队',
                  icon: Icons.groups_outlined,
                ),
              for (final team in teams)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Card(
                    child: ListTile(
                      title: Text(team.name),
                      subtitle: Text('编号 ${team.id}'),
                      trailing:
                          controller.spaces.any((space) => space.id == team.id)
                          ? IconButton(
                              tooltip: '管理团队',
                              icon: const Icon(Icons.settings_outlined),
                              onPressed: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => TeamDetails(controller, team),
                                ),
                              ),
                            )
                          : OutlinedButton(
                              onPressed: () => requestJoin(team),
                              child: const Text('申请加入'),
                            ),
                      onTap:
                          controller.spaces.any((space) => space.id == team.id)
                          ? () {
                              controller.selectSpace(team.id);
                              Navigator.pop(context);
                            }
                          : null,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class TeamEditor extends StatefulWidget {
  const TeamEditor(this.controller, {super.key, this.space});
  final TodoController controller;
  final Space? space;

  @override
  State<TeamEditor> createState() => _TeamEditorState();
}

class _TeamEditorState extends State<TeamEditor> {
  late String name = widget.space?.name ?? '';
  late String capacity = '${widget.space?.capacity ?? 8}';
  bool busy = false;

  Future<void> save() async {
    final maximum = int.tryParse(capacity);
    if (name.trim().isEmpty ||
        maximum == null ||
        maximum < 1 ||
        maximum > 999) {
      message(context, '请输入团队名称和 1–999 的成员上限');
      return;
    }
    setState(() => busy = true);
    try {
      final controller = widget.controller;
      final reply = await controller.api.call(
        '/team/base',
        method: widget.space == null ? 'POST' : 'PUT',
        values: {
          'name': name.trim(),
          'total_size': maximum,
          if (widget.space != null) 'team_id': widget.space!.id,
        },
      );
      final space = Space.fromJson(fields(reply['team']));
      await controller.mutate((workspace, _) {
        workspace.spaces = [
          ...workspace.spaces.where((item) => item.id != space.id),
          space,
        ];
      });
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) message(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.space == null ? '新建团队' : '编辑团队')),
    body: PageContent(
      children: [
        TextFormField(
          initialValue: name,
          decoration: const InputDecoration(labelText: '团队名称'),
          maxLength: 100,
          onChanged: (value) => name = value,
        ),
        TextFormField(
          initialValue: capacity,
          decoration: const InputDecoration(labelText: '成员上限'),
          keyboardType: TextInputType.number,
          onChanged: (value) => capacity = value,
        ),
        const SizedBox(height: 12),
        FilledButton(onPressed: busy ? null : save, child: const Text('保存')),
      ],
    ),
  );
}

class TeamDetails extends StatefulWidget {
  const TeamDetails(this.controller, this.team, {super.key});
  final TodoController controller;
  final Space team;

  @override
  State<TeamDetails> createState() => _TeamDetailsState();
}

class _TeamDetailsState extends State<TeamDetails> {
  late Future<Fields> members = load();
  bool get owner => widget.controller.identity.user == widget.team.owner;

  Future<Fields> load() => widget.controller.api.call(
    '/team/user',
    method: 'GET',
    values: {'team_id': widget.team.id},
  );

  Future<void> membership(int event, int recipient) async {
    final accepted = await confirm(context, switch (event) {
      15 => '退出团队？',
      16 => '移除成员？',
      _ => '解散团队？',
    }, '成员权限将立即更新。');
    if (!accepted || !mounted) return;
    try {
      final controller = widget.controller;
      await controller.api.call(
        '/message/base',
        values: {
          'type': 1,
          'event': event,
          'recipient': recipient,
          '_data': {'id': widget.team.id, 'name': widget.team.name},
        },
      );
      if (event == 16) {
        if (mounted) setState(() => members = load());
      } else {
        await controller.mutate(
          (data, _) => data.spaces = data.spaces
              .where((team) => team.id != widget.team.id)
              .toList(),
        );
        if (controller.team == widget.team.id) {
          controller.selectSpace(controller.identity.personal);
        }
        if (mounted) Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) message(context, error);
    }
  }

  @override
  Widget build(BuildContext context) => LoadingPage(
    widget.team.name,
    members,
    (response) => [
      for (final user in fields(response['data']).values.whereType<Fields>())
        Card(
          child: ListTile(
            title: Text(text(user['nickname'])),
            subtitle: Text(
              integer(user['user_id']) == widget.team.owner ? '创建者' : '成员',
            ),
            trailing: owner && integer(user['user_id']) != widget.team.owner
                ? IconButton(
                    tooltip: '移除成员',
                    icon: const Icon(Icons.person_remove_outlined),
                    onPressed: () => membership(16, integer(user['user_id'])),
                  )
                : null,
          ),
        ),
      const SizedBox(height: 12),
      if (owner)
        OutlinedButton(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => TeamEditor(widget.controller, space: widget.team),
            ),
          ),
          child: const Text('编辑团队'),
        ),
      TextButton(
        onPressed: () => membership(owner ? 17 : 15, widget.team.owner),
        child: Text(owner ? '解散团队' : '退出团队'),
      ),
    ],
  );
}

class InboxPage extends StatefulWidget {
  const InboxPage(this.controller, {super.key});
  final TodoController controller;

  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> {
  late Future<Fields> messages = load();
  Future<Fields> load() => widget.controller.api.call(
    '/message/base',
    method: 'GET',
    values: {'page_size': 100},
  );

  Future<void> resolve(Fields row, int op) async {
    try {
      if (op == 0) {
        await widget.controller.api.call(
          '/message/base',
          method: 'PUT',
          values: {'message_id': row['message_id'], 'is_delete': 1},
        );
      } else {
        await widget.controller.api.call(
          '/message/base',
          values: {
            'type': 1,
            'event': 12,
            'message_id': row['message_id'],
            'recipient': row['from_user_id'],
            '_data': {...fields(row['content']), 'operate': op},
          },
        );
      }
      if (mounted) setState(() => messages = load());
    } catch (error) {
      if (mounted) message(context, error);
    }
  }

  @override
  Widget build(BuildContext context) => LoadingPage('消息', messages, (response) {
    final rows = objects(response['data']).toList();
    return [
      if (rows.isEmpty) const EmptyContent('暂无消息', icon: Icons.mail_outline),
      for (final row in rows)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Card(
            child: Column(
              children: [
                ListTile(
                  title: Text(switch (integer(row['event'])) {
                    11 => '加入团队申请',
                    12 =>
                      integer(fields(row['content'])['operate']) == 1
                          ? '申请已通过'
                          : '申请未通过',
                    15 => '成员退出团队',
                    16 => '已被移出团队',
                    _ => '团队消息',
                  }),
                  subtitle: Text(
                    '${text(row['from_user_nickname'])} · ${text(fields(row['content'])['name'])}',
                  ),
                  trailing: IconButton(
                    tooltip: '删除消息',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => resolve(row, 0),
                  ),
                ),
                if (integer(row['event']) == 11 &&
                    integer(fields(row['content'])['operate']) == 0)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: OverflowBar(
                      alignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => resolve(row, 2),
                          child: const Text('拒绝'),
                        ),
                        FilledButton(
                          onPressed: () => resolve(row, 1),
                          child: const Text('同意'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
    ];
  });
}

class CommentsPage extends StatefulWidget {
  const CommentsPage(this.controller, this.task, {super.key});
  final TodoController controller;
  final Task task;
  @override
  State<CommentsPage> createState() => _CommentsPageState();
}

class _CommentsPageState extends State<CommentsPage> {
  final input = TextEditingController();
  late Future<Fields> rows = load();
  bool sending = false;
  Map<String, Object> get task => {
    'team_id': widget.task.team,
    'task_id': widget.task.uid,
  };
  Future<Fields> load() async {
    await widget.controller.sync();
    return widget.controller.api.call(
      '/comment/list',
      values: {...task, 'page_size': 100},
    );
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> send() async {
    final text = input.text.trim();
    if (text.isEmpty || sending) return;
    setState(() => sending = true);
    try {
      await widget.controller.api.call(
        '/comment/create',
        values: {...task, 'comment': text},
      );
      if (mounted) {
        input.clear();
        setState(() => rows = load());
      }
    } catch (error) {
      if (mounted) message(context, error);
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => LoadingPage(
    '评论',
    rows,
    (response) => [
      TextFormField(
        controller: input,
        maxLength: 4000,
        maxLines: 3,
        decoration: const InputDecoration(labelText: '新增评论'),
      ),
      FilledButton(onPressed: sending ? null : send, child: const Text('发送评论')),
      const SizedBox(height: 12),
      for (final row in objects(response['data']))
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Card(
            child: ListTile(
              title: Text(text(row['comment'])),
              subtitle: Text(
                '${text(row['nickname'])} · ${text(row['created_at'])}',
              ),
            ),
          ),
        ),
    ],
  );
}

class AssigneesPage extends StatefulWidget {
  const AssigneesPage(this.controller, this.task, {super.key});
  final TodoController controller;
  final Task task;
  @override
  State<AssigneesPage> createState() => _AssigneesPageState();
}

class _AssigneesPageState extends State<AssigneesPage> {
  late final Future<Fields> members = widget.controller.api.call(
    '/team/user',
    method: 'GET',
    values: {'team_id': widget.task.team},
  );

  Future<void> select(int user, bool enable) async {
    try {
      await widget.controller.mutate((data, who) {
        final task = findTask(data, who, widget.task.team, widget.task.uid);
        if (task == null) return;
        final member = task.members
            .where((row) => integer(row.data['user_id']) == user)
            .firstOrNull;
        if (enable && member == null) {
          data.save(who, task.team, Tables.assignee, newId(Tables.assignee), {
            'task_id': task.uid,
            'user_id': user,
            'role': 448,
            'status': 0,
            'sequence': 0,
          });
        } else if (!enable) {
          data.remove(member);
        }
      });
    } catch (error) {
      if (mounted) message(context, error);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final task = findTask(
        widget.controller.data,
        widget.controller.identity,
        widget.task.team,
        widget.task.uid,
      );
      final assigned = {
        for (final member in task?.members ?? <Item>[])
          integer(member.data['user_id']),
      };
      final owner = integer(widget.task.row.data['user_id']);
      return LoadingPage(
        '参与人',
        members,
        (response) => [
          for (final member in fields(
            response['data'],
          ).values.whereType<Fields>())
            CheckboxListTile(
              title: Text(text(member['nickname'])),
              value: assigned.contains(integer(member['user_id'])),
              subtitle: integer(member['user_id']) == owner
                  ? const Text('任务创建者')
                  : null,
              onChanged:
                  widget.controller.identity.user != owner ||
                      integer(member['user_id']) == owner
                  ? null
                  : (value) =>
                        select(integer(member['user_id']), value == true),
            ),
        ],
      );
    },
  );
}
