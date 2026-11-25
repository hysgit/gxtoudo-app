import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'appearance.dart';
import 'api.dart';
import 'bill_location.dart';
import 'controller.dart';
import 'domain.dart';
import 'ledger.dart';
import 'media_files.dart';
import 'record_attachments.dart';
import 'record_history_page.dart';

class BillEditor extends StatefulWidget {
  const BillEditor(
    this.controller,
    this.team, {
    super.key,
    this.bill,
    this.files,
    this.locationLoader,
  });
  final TodoController controller;
  final int team;
  final Item? bill;
  final MediaFiles? files;
  final Future<BillLocation?> Function()? locationLoader;
  @override
  State<BillEditor> createState() => _BillEditorState();
}

class _BillEditorState extends State<BillEditor> {
  final form = GlobalKey<FormState>();
  late final uid = widget.bill?.uid ?? newId(Tables.bill);
  late final scope = widget.controller.identity.scope;
  late final files = widget.files ?? MediaFiles();
  late final subject = TextEditingController(text: widget.bill?.name);
  late final amount = TextEditingController(
    text: text(widget.bill?.data['amount']),
  );
  late String currency = billCurrency(widget.bill?.data ?? {});
  late final remark = TextEditingController(
    text: text(widget.bill?.data['remark']),
  );
  late final location = TextEditingController(
    text: text(widget.bill?.data['location']),
  );
  late DateTime date =
      DateTime.tryParse(text(widget.bill?.data['date'])) ?? DateTime.now();
  late String type = text(widget.bill?.data['type']).isEmpty
      ? 'expense'
      : text(widget.bill!.data['type']);
  late String channel = text(widget.bill?.data['channel']).isEmpty
      ? paymentChannels.first
      : text(widget.bill!.data['channel']);
  late String party = text(widget.bill?.data['party']).isEmpty
      ? paymentParties.first
      : text(widget.bill!.data['party']);
  late String latitude = text(widget.bill?.data['latitude']),
      longitude = text(widget.bill?.data['longitude']);
  late bool included = billIncluded(widget.bill?.data ?? {});
  final draft = AttachmentDraft();
  bool busy = false,
      attaching = false,
      locating = false,
      dirty = false,
      leaving = false;
  Future<void>? locationWork;

  @override
  void initState() {
    super.initState();
    for (final input in [subject, amount, remark]) {
      input.addListener(changed);
    }
    if (widget.bill == null) locationWork = refreshLocation();
  }

  void changed() {
    if (!dirty && mounted) setState(() => dirty = true);
  }

  void report(Object error) {
    if (!mounted) return;
    message(
      context,
      error is FormatException
          ? error.message
          : error is ApiFailure
          ? error.message
          : '操作未完成，请检查权限或本地存储后重试',
    );
  }

  @override
  void dispose() {
    for (final input in [subject, amount, remark, location]) {
      input.dispose();
    }
    super.dispose();
  }

  Future<void> refreshLocation() async {
    if (mounted) setState(() => locating = true);
    try {
      final value = await (widget.locationLoader ?? locateBill)();
      if (!mounted) return;
      if (value != null) {
        setState(() {
          location.text = value.label;
          latitude = value.latitude;
          longitude = value.longitude;
          if (widget.bill != null) dirty = true;
        });
      } else {
        message(context, '定位未授权或不可用，仍可保存账单');
      }
    } catch (_) {
      if (mounted) message(context, '暂时无法定位，仍可保存账单');
    } finally {
      if (mounted) setState(() => locating = false);
    }
  }

  Future<void> addOption(String kind) async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => _OptionDialog(kind),
    );
    if (value == null || !mounted) return;
    try {
      await widget.controller.mutate((data, who) {
        if (who.scope != scope) throw const FormatException('账户已切换');
        if (!data.items.values
            .where((row) => !row.removed && row.table == Tables.billOption)
            .any((row) => row.data['kind'] == kind && row.name == value)) {
          data.save(
            who,
            who.personal,
            Tables.billOption,
            newId(Tables.billOption),
            {'kind': kind, 'name': value},
          );
        }
      });
      if (mounted) selectChoice(kind, value);
    } catch (error) {
      report(error);
    }
  }

  Future<void> save() async {
    if (busy || attaching || form.currentState?.validate() != true) return;
    setState(() => busy = true);
    try {
      if (locating && locationWork != null) {
        await locationWork!.timeout(
          const Duration(seconds: 8),
          onTimeout: () {},
        );
      }
      final values = {
        'name': subject.text.trim(),
        'date': billDate(date),
        'type': type,
        'amount': amount.text,
        'currency': currency,
        'include_in_totals': included ? 1 : 0,
        'channel': channel,
        'party': party,
        'remark': remark.text,
        'location': location.text,
        'latitude': latitude,
        'longitude': longitude,
      };
      await widget.controller.mutate((data, who) {
        if (who.scope != scope) throw const FormatException('账户已切换，请重新打开账单');
        if (widget.bill != null &&
            data.get(widget.team, Tables.bill, uid) == null) {
          throw const FormatException('账单已删除');
        }
        saveBill(
          data,
          who,
          widget.team,
          uid,
          values,
          draft.additions,
          draft.media,
          removed: draft.removed,
        );
      });
      if (mounted) {
        setState(() => leaving = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context);
        });
      }
    } catch (error) {
      report(error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> remove() async {
    if (!await confirm(context, '删除账单？', '账单将移入回收站，可以恢复。') || !mounted) {
      return;
    }
    setState(() => busy = true);
    try {
      await widget.controller.mutate((data, who) {
        if (who.scope != scope) throw const FormatException('账户已切换');
        final bill = data.get(widget.team, Tables.bill, uid);
        if (bill == null) return;
        captureBill(data, who, bill, onlyIfMissing: true);
        captureBill(data, who, bill, action: '删除');
        data.remove(bill);
      });
      if (mounted) {
        setState(() => leaving = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context);
        });
      }
    } catch (error) {
      report(error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> leave() async {
    if (busy || attaching) return;
    if (dirty && !await confirm(context, '放弃未保存的账单修改？', '已经保存的账单会保留。')) return;
    if (mounted) {
      setState(() => leaving = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    }
  }

  void selectChoice(String kind, String value) {
    setState(() {
      if (kind == 'channel') {
        channel = value;
        if (value == '微信') party = '微信余额';
      } else {
        party = value;
      }
      dirty = true;
    });
  }

  Widget choices(String kind, String value) {
    final isChannel = kind == 'channel';
    final label = isChannel
        ? '途径'
        : switch (type) {
            'expense' => '支出方',
            'income' => '收入方',
            _ => '收支方',
          };
    final options = {
      ...billChoices(widget.controller.data, widget.team, kind),
      value,
    };
    return Row(
      children: [
        Expanded(
          child: PopupMenuButton<String>(
            initialValue: value,
            enabled: !busy,
            tooltip: label,
            position: PopupMenuPosition.under,
            onSelected: (next) => selectChoice(kind, next),
            itemBuilder: (_) => [
              for (final item in options)
                PopupMenuItem(value: item, height: 40, child: Text(item)),
            ],
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: label,
                enabled: !busy,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 14,
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Icon(Icons.arrow_drop_down, size: 18),
                ],
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: isChannel ? '新增途径' : '新增支出方/收入方',
          onPressed: busy ? null : () => addOption(kind),
          style: IconButton.styleFrom(
            minimumSize: const Size(36, 44),
            padding: EdgeInsets.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          icon: const Icon(Icons.add, size: 20),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: leaving || (!dirty && !busy && !attaching),
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(leave());
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(widget.bill == null ? '新建账单' : '编辑账单'),
        actions: [
          if (widget.bill case final bill?)
            IconButton(
              tooltip: '历史版本',
              icon: const Icon(Icons.history),
              onPressed: busy || attaching
                  ? null
                  : () async {
                      if (dirty &&
                          !await confirm(
                            context,
                            '查看历史版本？',
                            '还原历史版本会替换当前未保存的修改。',
                          )) {
                        return;
                      }
                      if (!context.mounted) return;
                      final restored = await Navigator.push<bool>(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              RecordHistoryPage(widget.controller, bill),
                        ),
                      );
                      if (restored == true && mounted) {
                        setState(() => leaving = true);
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) Navigator.pop(context);
                        });
                      }
                    },
            ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              onPressed: busy || attaching ? null : save,
              child: const Text('保存'),
            ),
          ),
        ],
      ),
      body: Form(
        key: form,
        child: PageContent(
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.calendar_today_outlined),
              title: const Text('日期'),
              subtitle: Text(billDate(date)),
              onTap: busy
                  ? null
                  : () async {
                      final selected = await showDatePicker(
                        context: context,
                        initialDate: date,
                        firstDate: DateTime(1900),
                        lastDate: DateTime.now(),
                      );
                      if (selected != null && mounted) {
                        setState(() {
                          date = selected;
                          dirty = true;
                        });
                      }
                    },
            ),
            DropdownButtonFormField<String>(
              initialValue: type,
              decoration: const InputDecoration(labelText: '类型'),
              items: [
                for (final entry in billTypes.entries)
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
              ],
              onChanged: busy
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() {
                          type = value;
                          dirty = true;
                        });
                      }
                    },
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    controller: amount,
                    enabled: !busy,
                    decoration: const InputDecoration(labelText: '金额'),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    validator: (value) {
                      try {
                        ExactAmount.parse(value ?? '');
                        return null;
                      } on FormatException catch (error) {
                        return error.message;
                      }
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: DropdownButtonFormField<String>(
                    initialValue: currency,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '币种'),
                    items: [
                      for (final entry in billCurrencies.entries)
                        DropdownMenuItem(
                          value: entry.key,
                          child: Text(
                            entry.value,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      if (!billCurrencies.containsKey(currency))
                        DropdownMenuItem(
                          value: currency,
                          child: Text(currency),
                        ),
                    ],
                    onChanged: busy
                        ? null
                        : (value) => setState(() {
                            currency = value!;
                            dirty = true;
                          }),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                type == 'income'
                    ? '计入总收入'
                    : type == 'expense'
                    ? '计入总支出'
                    : '内转不计入收支',
              ),
              value: type == 'transfer' ? false : included,
              onChanged: busy || type == 'transfer'
                  ? null
                  : (value) => setState(() {
                      included = value ?? true;
                      dirty = true;
                    }),
            ),
            Row(
              children: [
                Expanded(child: choices('channel', channel)),
                const SizedBox(width: 8),
                Expanded(child: choices('party', party)),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: subject,
              enabled: !busy,
              maxLength: 500,
              decoration: const InputDecoration(labelText: '事项'),
              validator: (value) =>
                  value?.trim().isNotEmpty == true ? null : '请输入事项',
            ),
            TextFormField(
              controller: location,
              readOnly: true,
              decoration: InputDecoration(
                labelText: '地点',
                hintText: locating ? '正在定位…' : '未定位',
                suffixIcon: IconButton(
                  tooltip: '重新定位',
                  onPressed: locating
                      ? null
                      : () {
                          locationWork = refreshLocation();
                        },
                  icon: const Icon(Icons.my_location),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: remark,
              enabled: !busy,
              minLines: 2,
              maxLines: 5,
              maxLength: 12000,
              decoration: const InputDecoration(labelText: '备注'),
            ),
            RecordAttachments(
              controller: widget.controller,
              team: widget.team,
              table: Tables.billAttachment,
              parent: uid,
              draft: draft,
              files: files,
              locked: busy,
              onState: (active, changed) => setState(() {
                attaching = active;
                dirty = dirty || changed;
              }),
            ),
            if (widget.bill != null)
              TextButton(
                onPressed: busy || attaching ? null : remove,
                child: Text(
                  '删除账单',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class _OptionDialog extends StatefulWidget {
  const _OptionDialog(this.kind);
  final String kind;
  @override
  State<_OptionDialog> createState() => _OptionDialogState();
}

class _OptionDialogState extends State<_OptionDialog> {
  final input = TextEditingController();
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.kind == 'channel' ? '新增途径' : '新增支出方/收入方'),
    content: TextField(
      controller: input,
      autofocus: true,
      maxLength: 100,
      decoration: const InputDecoration(labelText: '名称'),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (input.text.trim().isNotEmpty) {
            Navigator.pop(context, input.text.trim());
          }
        },
        child: const Text('添加'),
      ),
    ],
  );
}
