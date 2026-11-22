import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'appearance.dart';
import 'controller.dart';
import 'domain.dart';
import 'schedule.dart';

class PricePage extends StatefulWidget {
  const PricePage(this.controller, {required this.onLogin, super.key});
  final TodoController controller;
  final VoidCallback onLogin;
  @override
  State<PricePage> createState() => _PricePageState();
}

class _PricePageState extends State<PricePage> {
  List<Fields> watches = [];
  bool loading = true, paired = false;
  String error = '';
  int seen = 0;

  @override
  void initState() {
    super.initState();
    if (widget.controller.account != null) load();
  }

  Future<void> load() async {
    try {
      final result = await widget.controller.api.call(
        '/price/watch',
        method: 'GET',
      );
      if (mounted) {
        setState(() {
          watches = objects(result['data']).toList();
          paired = result['collector_paired'] == true;
          seen = integer(result['collector_seen']);
          error = '';
          loading = false;
        });
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          error = failure.toString();
          loading = false;
        });
      }
    }
  }

  Future<void> create() async {
    final values = await showDialog<Fields>(
      context: context,
      builder: (_) => const _WatchDialog(),
    );
    if (values == null || !mounted) return;
    try {
      await widget.controller.api.call('/price/watch', values: values);
      await load();
    } catch (failure) {
      if (mounted) message(context, failure);
    }
  }

  Future<void> pair() async {
    if (paired && !await confirm(context, '重新配对采集端？', '旧配对码将失效。')) return;
    try {
      final result = await widget.controller.api.call(
        '/price/collector',
        method: 'PUT',
      );
      if (!mounted) return;
      final token = text(result['collector_token']);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('配对浏览器采集端'),
          content: const Text('在运行追踪的电脑上输入配对码，然后用手机扫码登录京东、淘宝。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
            FilledButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: token));
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('复制配对码'),
            ),
          ],
        ),
      );
      await load();
    } catch (failure) {
      if (mounted) message(context, failure);
    }
  }

  Future<void> unpair() async {
    if (!await confirm(context, '解除配对？', '电脑上的采集端将停止上报。')) return;
    try {
      await widget.controller.api.call('/price/collector', method: 'DELETE');
      await load();
    } catch (failure) {
      if (mounted) message(context, failure);
    }
  }

  Future<void> remove(Fields row) async {
    if (!await confirm(context, '停止追踪？', text(row['name']))) return;
    try {
      await widget.controller.api.call(
        '/price/watch',
        method: 'DELETE',
        values: {'id': row['id']},
      );
      await load();
    } catch (failure) {
      if (mounted) message(context, failure);
    }
  }

  void history(Fields row) => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => LoadingPage(
        text(row['name']),
        widget.controller.api.call(
          '/price/history',
          method: 'GET',
          values: {'id': row['id']},
        ),
        (result) => [
          ListTile(
            title: Text(text(row['variant'])),
            subtitle: Text('${row['quantity']} 件 · ${row['region']}'),
          ),
          if (objects(result['data']).isEmpty) const EmptyContent('等待首次核验'),
          for (final point in objects(result['data']))
            ListTile(
              title: Text('¥${_amount(point['amount'])}'),
              subtitle: Text(
                '${_date(integer(point['observed_at']))}\n${text(point['details'])}',
              ),
            ),
        ],
      ),
    ),
  );

  static String _date(int epoch) {
    final date = localTime(epoch);
    return '${date.year}-${pad(date.month)}-${pad(date.day)} ${clock(date)}';
  }

  static String _amount(Object? value) {
    final amount = text(value);
    if (!amount.contains('.')) return '$amount.00';
    final parts = amount.split('.');
    return '${parts.first}.${parts.last.replaceFirst(RegExp(r'0+$'), '').padRight(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.controller.account == null) {
      return Center(
        child: FilledButton(
          onPressed: widget.onLogin,
          child: const Text('登录后追踪价格'),
        ),
      );
    }
    if (loading) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 18),
        children: [
          ListTile(
            title: Text(paired ? '采集端已配对' : '配对采集端'),
            subtitle: Text(seen == 0 ? '在电脑扫码登录京东、淘宝' : '最后连接 ${_date(seen)}'),
            onTap: pair,
            trailing: PopupMenuButton<String>(
              tooltip: '采集端设置',
              onSelected: (choice) {
                if (choice == 'pair') {
                  pair();
                } else {
                  unpair();
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'pair',
                  child: Text(paired ? '重新配对' : '获取配对码'),
                ),
                if (paired)
                  const PopupMenuItem(value: 'unpair', child: Text('解除配对')),
              ],
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: create,
              icon: const Icon(Icons.add),
              label: const Text('添加商品'),
            ),
          ),
          if (error.isNotEmpty)
            ListTile(
              title: Text(error),
              onTap: load,
              trailing: const Icon(Icons.refresh),
            ),
          if (watches.isEmpty && error.isEmpty) const EmptyContent('还没有追踪的商品'),
          for (final row in watches)
            ListTile(
              dense: true,
              title: Text(text(row['name'])),
              subtitle: Text(
                '${row['platform'] == 'jd' ? '京东' : '淘宝'} · ${row['variant']} · ${row['region']}\n'
                '${switch (row['state']) {
                  'verified' => '已核验 ${_date(integer(row['observed_at']))}',
                  'login_required' => '需要重新扫码登录',
                  'unavailable' => '暂时无法读取',
                  'needs_verification' => '需要核对商品或价格口径',
                  _ => '等待首次核验',
                }}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => history(row),
              onLongPress: () => remove(row),
              trailing: row['amount'] == null
                  ? const Icon(Icons.chevron_right)
                  : Text('¥${_amount(row['amount'])}'),
            ),
        ],
      ),
    );
  }
}

class _WatchDialog extends StatefulWidget {
  const _WatchDialog();
  @override
  State<_WatchDialog> createState() => _WatchDialogState();
}

class _WatchDialogState extends State<_WatchDialog> {
  final form = GlobalKey<FormState>();
  final fields = {
    'url': TextEditingController(),
    'name': TextEditingController(),
    'variant': TextEditingController(),
    'quantity': TextEditingController(text: '1'),
    'region': TextEditingController(),
  };

  @override
  void dispose() {
    for (final field in fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  Widget field(String key, String label, {int limit = 120}) => TextFormField(
    controller: fields[key],
    maxLength: limit,
    keyboardType: switch (key) {
      'url' => TextInputType.url,
      'quantity' => TextInputType.number,
      _ => TextInputType.text,
    },
    decoration: InputDecoration(labelText: label, counterText: ''),
    validator: (value) {
      if (text(value).trim().isEmpty) return '请输入$label';
      if (key == 'quantity' && (integer(value) < 1 || integer(value) > 100)) {
        return '数量须为 1 至 100';
      }
      return null;
    },
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('添加追踪商品'),
    content: Form(
      key: form,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            field('url', '商品详情链接', limit: 2048),
            field('name', '商品名称'),
            field('variant', '规格', limit: 150),
            field('quantity', '数量', limit: 3),
            field('region', '收货地区'),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (form.currentState?.validate() != true) return;
          Navigator.pop(context, {
            for (final entry in fields.entries)
              entry.key: entry.key == 'quantity'
                  ? integer(entry.value.text)
                  : entry.value.text.trim(),
          });
        },
        child: const Text('添加'),
      ),
    ],
  );
}
