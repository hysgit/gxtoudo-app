import 'package:material_ui/material_ui.dart';

import 'api.dart';
import 'appearance.dart';
import 'domain.dart';
import 'price_login_page.dart';

class PriceCartPage extends StatefulWidget {
  const PriceCartPage(
    this.api, {
    required this.initialPlatform,
    this.lastRegion = '',
    super.key,
  });
  final TodoApi api;
  final String initialPlatform, lastRegion;

  @override
  State<PriceCartPage> createState() => _PriceCartPageState();
}

class _PriceCartPageState extends State<PriceCartPage> {
  late String platform = widget.initialPlatform;
  List<Fields> rows = [];
  String error = '';
  bool loading = true, saving = false, needsLogin = false;
  int request = 0;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final seq = ++request;
    setState(() {
      rows = [];
      error = '';
      needsLogin = false;
      loading = true;
    });
    try {
      final response = await widget.api.call(
        '/price/login',
        timeout: const Duration(seconds: 29),
        values: {'platform': platform, 'action': 'cart_list'},
      );
      if (!mounted || seq != request) return;
      setState(
        () => rows = objects(fields(response['data'])['items']).toList(),
      );
    } catch (failure) {
      if (!mounted || seq != request) return;
      setState(() {
        error = failure.toString();
        needsLogin = failure is ApiFailure && failure.status == '411';
      });
    } finally {
      if (mounted && seq == request) setState(() => loading = false);
    }
  }

  Future<void> signIn() async {
    final saved = await Navigator.push<int>(
      context,
      MaterialPageRoute(builder: (_) => PriceLoginPage(widget.api, platform)),
    );
    if (mounted && saved != null) await load();
  }

  Future<void> add(Fields row) async {
    if (saving || loading) return;
    final selectedPlatform = platform;
    final region = await showDialog<String>(
      context: context,
      builder: (_) => _CartRegion(row, widget.lastRegion),
    );
    if (region == null || !mounted) return;
    setState(() => saving = true);
    try {
      await widget.api.call(
        '/price/from-cart',
        values: {
          'platform': selectedPlatform,
          'selection': row['selection'],
          'region': region,
        },
      );
      if (mounted) Navigator.pop(context, true);
    } catch (failure) {
      if (mounted) message(context, failure);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('从购物车选商品'),
      actions: [
        IconButton(
          tooltip: '刷新购物车',
          onPressed: loading || saving ? null : load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: SafeArea(
      top: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'jd', label: Text('京东')),
                ButtonSegment(value: 'taobao', label: Text('淘宝')),
              ],
              selected: {platform},
              onSelectionChanged: saving || loading
                  ? null
                  : (value) {
                      if (value.single == platform) return;
                      platform = value.single;
                      load();
                    },
            ),
          ),
          if (loading)
            const Padding(
              padding: EdgeInsets.all(20),
              child: CircularProgressIndicator(),
            )
          else if (error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Text(error),
                  if (needsLogin)
                    TextButton(
                      onPressed: signIn,
                      child: Text(platform == 'jd' ? '登录京东' : '登录淘宝'),
                    ),
                ],
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                itemCount: rows.length,
                itemBuilder: (context, index) {
                  final row = rows[index];
                  return ListTile(
                    title: Text(text(row['name'])),
                    subtitle: Text('${row['variant']} · ${row['quantity']} 件'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: saving ? null : () => add(row),
                  );
                },
              ),
            ),
        ],
      ),
    ),
  );
}

class _CartRegion extends StatefulWidget {
  const _CartRegion(this.row, this.region);
  final Fields row;
  final String region;
  @override
  State<_CartRegion> createState() => _CartRegionState();
}

class _CartRegionState extends State<_CartRegion> {
  late final input = TextEditingController(text: widget.region);
  final form = GlobalKey<FormState>();
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('添加到追踪'),
    content: SingleChildScrollView(
      child: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(text(widget.row['name'])),
            Text(
              '${widget.row['variant']} · ${widget.row['quantity']} 件',
              style: const TextStyle(color: muted),
            ),
            TextFormField(
              controller: input,
              maxLength: 120,
              decoration: const InputDecoration(
                labelText: '收货地区',
                counterText: '',
              ),
              validator: (value) =>
                  (value ?? '').trim().isEmpty ? '请输入收货地区' : null,
            ),
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
          if (form.currentState?.validate() == true) {
            Navigator.pop(context, input.text.trim());
          }
        },
        child: const Text('添加'),
      ),
    ],
  );
}
