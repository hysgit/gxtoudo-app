import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'appearance.dart';
import 'api.dart';
import 'bill_location.dart';
import 'controller.dart';
import 'domain.dart';
import 'ledger.dart';
import 'media_files.dart';
import 'note_bubble.dart';

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

class _BillEditorState extends State<BillEditor> with WidgetsBindingObserver {
  final form = GlobalKey<FormState>();
  late final uid = widget.bill?.uid ?? newId(Tables.bill);
  late final scope = widget.controller.identity.scope;
  late final files = widget.files ?? MediaFiles();
  late final subject = TextEditingController(text: widget.bill?.name);
  late final amount = TextEditingController(
    text: text(widget.bill?.data['amount']),
  );
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
  late final attachments = widget.controller.data
      .list(widget.team, Tables.billAttachment)
      .where((row) => row.data['note_id'] == uid)
      .map((row) => {...row.data, 'uid': row.uid})
      .toList();
  final localMedia = <String, Fields>{};
  final removed = <String>{};
  AudioRecorder? _recorder;
  AudioRecorder get recorder => _recorder ??= AudioRecorder();
  Timer? timer;
  bool busy = false,
      recording = false,
      locating = false,
      dirty = false,
      leaving = false;
  int duration = 0;
  Future<void>? locationWork;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    if (_recorder != null) unawaited(_recorder!.dispose());
    for (final input in [subject, amount, remark, location]) {
      input.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && recording) {
      unawaited(stopRecording());
    }
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
      if (mounted) {
        setState(() {
          if (kind == 'channel') {
            channel = value;
          } else {
            party = value;
          }
          dirty = true;
        });
      }
    } catch (error) {
      report(error);
    }
  }

  Future<void> addAttachment(
    String path,
    String kind,
    String name, {
    int durationMs = 0,
  }) async {
    final metadata = await files.importFile(File(path), kind, name: name);
    if (!mounted) return;
    final id = text(metadata['client_media_id']);
    setState(() {
      localMedia[id] = {
        ...metadata,
        'note_id': uid,
        'team_id': widget.team,
        'parent_table': Tables.bill,
      };
      attachments.add({
        ...metadata,
        'uid': newId(Tables.billAttachment),
        'note_id': uid,
        'parent_table': Tables.bill,
        'media_id': '',
        'media_name': name,
        'entry_at': DateTime.now().millisecondsSinceEpoch,
        'duration_ms': durationMs,
      });
      dirty = true;
    });
  }

  Future<void> pick(String source) async {
    setState(() => busy = true);
    try {
      if (source == 'camera') {
        final value = await ImagePicker().pickImage(
          source: ImageSource.camera,
          imageQuality: 100,
        );
        if (value != null) await addAttachment(value.path, 'image', value.name);
      } else {
        final values = await FilePicker.platform.pickFiles(
          type: source == 'image' ? FileType.image : FileType.any,
          allowMultiple: true,
          compressionQuality: 0,
          withData: false,
        );
        for (final value in values?.files ?? <PlatformFile>[]) {
          if (value.path != null) {
            await addAttachment(
              value.path!,
              source == 'image' ? 'image' : 'file',
              value.name,
            );
          }
        }
      }
    } catch (error) {
      report(error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> record() async {
    if (recording) return stopRecording();
    setState(() => busy = true);
    try {
      if (!await recorder.hasPermission()) {
        if (mounted) message(context, '请允许麦克风权限');
        return;
      }
      final root = await getTemporaryDirectory();
      await recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000),
        path: '${root.path}/${newId('bill-voice')}.m4a',
      );
      if (!mounted) return;
      setState(() {
        recording = true;
        duration = 0;
      });
      timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => duration++);
        if (duration >= 3600) unawaited(stopRecording());
      });
    } catch (error) {
      report(error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> stopRecording() async {
    if (!recording) return;
    timer?.cancel();
    setState(() {
      recording = false;
      busy = true;
    });
    try {
      final path = await recorder.stop();
      if (path != null) {
        await addAttachment(
          path,
          'audio',
          '录音.m4a',
          durationMs: duration * 1000,
        );
      }
    } catch (error) {
      report(error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    if (busy || recording || form.currentState?.validate() != true) return;
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
          attachments,
          localMedia,
          removed: removed,
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
    if (!await confirm(context, '删除账单？', '账单和附件记录将删除，并自动同步。') || !mounted) {
      return;
    }
    setState(() => busy = true);
    try {
      await widget.controller.mutate((data, _) {
        data.remove(data.get(widget.team, Tables.bill, uid));
        for (final row
            in data.list(widget.team, Tables.billAttachment).toList()) {
          if (row.data['note_id'] == uid) data.remove(row);
        }
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
    if (busy || recording) return;
    if (dirty && !await confirm(context, '放弃未保存的账单修改？', '已经保存的账单会保留。')) return;
    if (mounted) {
      setState(() => leaving = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    }
  }

  Widget choices(String kind, String value) {
    final options = {
      ...billChoices(widget.controller.data, widget.team, kind),
      value,
    };
    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            key: ValueKey('$kind-$value'),
            initialValue: value,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: kind == 'channel' ? '途径' : '支出方/收入方',
            ),
            items: [
              for (final item in options)
                DropdownMenuItem(
                  value: item,
                  child: Text(item, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: busy
                ? null
                : (next) {
                    if (next != null) {
                      setState(() {
                        if (kind == 'channel') {
                          channel = next;
                        } else {
                          party = next;
                        }
                        dirty = true;
                      });
                    }
                  },
          ),
        ),
        IconButton(
          tooltip: kind == 'channel' ? '新增途径' : '新增支出方/收入方',
          onPressed: busy ? null : () => addOption(kind),
          icon: const Icon(Icons.add),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: leaving || (!dirty && !busy && !recording),
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(leave());
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(widget.bill == null ? '新建账单' : '编辑账单'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              onPressed: busy || recording ? null : save,
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
            TextFormField(
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
            const SizedBox(height: 12),
            choices('channel', channel),
            const SizedBox(height: 12),
            choices('party', party),
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
            const Text('备注附件', style: TextStyle(color: muted)),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton.icon(
                  onPressed: busy || recording ? null : () => pick('image'),
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('相册'),
                ),
                OutlinedButton.icon(
                  onPressed: busy || recording ? null : () => pick('camera'),
                  icon: const Icon(Icons.camera_alt_outlined),
                  label: const Text('拍照'),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : record,
                  icon: Icon(
                    recording ? Icons.stop_circle_outlined : Icons.mic_none,
                  ),
                  label: Text(recording ? '结束录音 $duration 秒' : '录音'),
                ),
                OutlinedButton.icon(
                  onPressed: busy || recording ? null : () => pick('file'),
                  icon: const Icon(Icons.attach_file),
                  label: const Text('文件'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            for (final attachment in attachments)
              Column(
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      tooltip: '移除附件',
                      onPressed: busy || recording
                          ? null
                          : () => setState(() {
                              removed.add(text(attachment['uid']));
                              attachments.remove(attachment);
                              dirty = true;
                            }),
                      icon: const Icon(Icons.close),
                    ),
                  ),
                  NoteBubble(
                    key: ValueKey(attachment['uid']),
                    entry: attachment,
                    media: {
                      ...attachment,
                      ...?localMedia[text(attachment['client_media_id'])],
                      ...?widget.controller.data.media[text(
                        attachment['client_media_id'],
                      )],
                    },
                    files: files,
                    scope: scope,
                    enabled: !recording && !busy,
                    onLongPress: () {},
                    onRetry: () {
                      unawaited(
                        widget.controller.sync().catchError((Object _) => 0),
                      );
                    },
                  ),
                ],
              ),
            if (widget.bill != null)
              TextButton(
                onPressed: busy || recording ? null : remove,
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
