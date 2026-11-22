import 'package:material_ui/material_ui.dart';

import 'appearance.dart';
import 'cloud_pages.dart';
import 'controller.dart';
import 'domain.dart';
import 'media_files.dart';
import 'record_attachments.dart';
import 'record_history_page.dart';
import 'record_versions.dart';
import 'schedule.dart';
import 'tasks.dart';

class TaskEditor extends StatefulWidget {
  const TaskEditor({
    super.key,
    required this.controller,
    required this.team,
    this.task,
    this.day,
    this.project = '',
    this.onReminder,
  });
  final TodoController controller;
  final int team;
  final Task? task;
  final DateTime? day;
  final String project;
  final Future<void> Function(String mode)? onReminder;

  @override
  State<TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends State<TaskEditor> {
  final form = GlobalKey<FormState>();
  late final scope = widget.controller.identity.scope;
  late final uid = widget.task?.uid ?? newId(Tables.task);
  final draft = AttachmentDraft();
  final mediaFiles = MediaFiles();
  late final name = TextEditingController(text: widget.task?.name);
  late final remark = TextEditingController(text: widget.task?.detail(2));
  late final review = TextEditingController(text: widget.task?.detail(1));
  late final tags = TextEditingController(
    text: widget.task?.tags
        .map((item) => text(item.data['tag_name']))
        .join('，'),
  );
  late final children = TextEditingController(
    text: widget.task?.children.map((item) => item.name).join('\n'),
  );
  late int selectedTeam = widget.task?.team ?? widget.team;
  List<Item> get projects =>
      widget.controller.data.list(selectedTeam, Tables.project).toList();
  List<Item> get places =>
      widget.controller.data.list(selectedTeam, Tables.place).toList();
  int get sourceTeam => widget.task?.team ?? widget.team;
  bool get moving => widget.task != null && sourceTeam != selectedTeam;
  Map<int, String> get spaceOptions {
    final values = {
      for (final space in widget.controller.spaces) space.id: space.name,
    };
    if (!values.containsKey(sourceTeam)) {
      values[sourceTeam] = sourceTeam == widget.controller.identity.personal
          ? '个人空间'
          : '当前空间';
    }
    return values;
  }

  late int rank = widget.task?.rank ?? 1;
  late String project = widget.task?.project ?? widget.project;
  late String place = widget.task?.place ?? '';
  late int repeat = repeatKind(widget.task?.repeat?.data);
  late int lead = widget.task == null
      ? 0
      : integer(widget.task?.alert?.data['alert_time'], -1);
  late String mode = reminderMode(widget.task?.alert);
  late bool allDay = widget.task?.allDay ?? false;
  late DateTime? date = (widget.task?.start ?? 0) > 0
      ? dayOnly(localTime(widget.task!.start))
      : widget.day;
  late TimeOfDay time = (widget.task?.start ?? 0) > 0
      ? TimeOfDay.fromDateTime(localTime(widget.task!.start))
      : const TimeOfDay(hour: 9, minute: 0);
  late DateTime? end = (widget.task?.end ?? 0) > 0
      ? localTime(widget.task!.end)
      : null;
  late DateTime? repeatEnd =
      integer(widget.task?.repeat?.data['repeat_end']) > 0
      ? dayOnly(localTime(integer(widget.task!.repeat!.data['repeat_end'])))
      : null;
  bool busy = false, attaching = false;

  @override
  void dispose() {
    for (final field in [name, remark, review, tags, children]) {
      field.dispose();
    }
    super.dispose();
  }

  Future<DateTime?> pickDay(DateTime? initial) => showDatePicker(
    context: context,
    initialDate: initial ?? DateTime.now(),
    firstDate: DateTime(1970),
    lastDate: DateTime(2099, 12, 31),
  );

  Future<void> changeDate() async {
    final value = await pickDay(date);
    if (!mounted || value == null) return;
    setState(() {
      if (date != null && end != null) {
        final elapsed = DateTime.utc(
          value.year,
          value.month,
          value.day,
        ).difference(DateTime.utc(date!.year, date!.month, date!.day)).inDays;
        end = DateTime(
          end!.year,
          end!.month,
          end!.day + elapsed,
          end!.hour,
          end!.minute,
        );
      }
      date = value;
    });
  }

  Future<void> changeTime() async {
    final value = await showTimePicker(context: context, initialTime: time);
    if (value != null && mounted) setState(() => time = value);
  }

  void changeSpace(int value) {
    setState(() {
      selectedTeam = value;
      if (!projects.any((item) => item.uid == project)) project = '';
      if (!places.any((item) => item.uid == place)) place = '';
    });
  }

  Future<void> changeEnd() async {
    final selected = await pickDay(end ?? date);
    if (!mounted || selected == null) return;
    final value = allDay
        ? const TimeOfDay(hour: 23, minute: 59)
        : await showTimePicker(
            context: context,
            initialTime: TimeOfDay.fromDateTime(end ?? DateTime.now()),
          );
    if (value != null && mounted) {
      setState(
        () => end = DateTime(
          selected.year,
          selected.month,
          selected.day,
          value.hour,
          value.minute,
        ),
      );
    }
  }

  Future<void> save() async {
    if (busy || attaching || form.currentState?.validate() != true) return;
    final day = date;
    final start = day == null
        ? 0
        : seconds(
            DateTime(
              day.year,
              day.month,
              day.day,
              allDay ? 0 : time.hour,
              allDay ? 0 : time.minute,
            ),
          );
    final stop = day == null
        ? 0
        : end == null
        ? allDay
              ? seconds(DateTime(day.year, day.month, day.day, 23, 59, 59))
              : start + 3600
        : seconds(
            allDay
                ? DateTime(end!.year, end!.month, end!.day, 23, 59, 59)
                : end!,
          );
    if (stop < start ||
        (repeat != 0 &&
            repeatEnd != null &&
            day != null &&
            repeatEnd!.isBefore(day))) {
      message(context, '结束时间必须在开始时间之后');
      return;
    }
    final last = day == null || repeatEnd == null || repeat == 0
        ? 0
        : seconds(addDays(repeatEnd!, 1)) - 1;
    final values = TaskChanges(
      name: name.text.trim(),
      rank: rank,
      project: project,
      place: place,
      start: start,
      end: stop,
      allDay: allDay,
      repeat: day == null ? 0 : repeat,
      repeatEnd: last,
      alert: lead,
      reminderMode: mode,
      remark: remark.text,
      review: review.text,
      tags: tags.text
          .split(RegExp('[,，]'))
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList(),
      children: children.text
          .split(RegExp(r'\r?\n'))
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList(),
    );
    setState(() => busy = true);
    try {
      final targetMembers = <int>{widget.controller.identity.user};
      final targetUid = moving ? newId(Tables.task) : uid;
      var targetDraft = draft;
      var sourceAttachments = <String>{};
      if (moving) {
        final response = await widget.controller.api.call(
          '/team/user',
          method: 'GET',
          values: {'team_id': selectedTeam},
        );
        targetMembers.addAll(
          fields(response['data']).values
              .whereType<Fields>()
              .map((member) => integer(member['user_id']))
              .where((user) => user > 0),
        );
        targetDraft = AttachmentDraft();
        final current = recordAttachments(
          widget.controller.data,
          sourceTeam,
          Tables.taskAttachment,
          uid,
        ).toList();
        sourceAttachments = current.map((row) => row.uid).toSet();
        for (final entry in [
          for (final row in current)
            if (!draft.removed.contains(row.uid)) row.data,
          ...draft.additions,
        ]) {
          final client = text(entry['client_media_id']);
          final file = await mediaFiles.find(client, entry, scope);
          if (file == null) throw const FormatException('请等任务附件同步到本机后再移动');
          final kind = text(entry['kind']);
          final name = text(entry['media_name']);
          final copy = await mediaFiles.importFile(file, kind, name: name);
          addDraftAttachment(
            targetDraft,
            copy,
            selectedTeam,
            Tables.taskAttachment,
            targetUid,
            name: name,
            durationMs: integer(entry['duration_ms']),
          );
        }
      }
      await widget.controller.mutate((data, who) {
        if (who.scope != scope) throw const FormatException('账户已切换，请重新打开任务');
        if (moving) {
          final latest = attachmentIds(
            data,
            sourceTeam,
            Tables.taskAttachment,
            uid,
          );
          if (latest.length != sourceAttachments.length ||
              !sourceAttachments.containsAll(latest)) {
            throw const FormatException('附件已变化，请重新打开任务后再移动');
          }
        }
        saveTask(
          data,
          who,
          sourceTeam,
          widget.task?.uid,
          values,
          targetTeam: selectedTeam,
          targetMembers: targetMembers,
          newUid: targetUid,
          attachments: targetDraft.additions,
          media: targetDraft.media,
          removedAttachments: targetDraft.removed,
        );
      });
      if (moving) widget.controller.selectSpace(selectedTeam);
      if (lead >= 0 && start > 0) {
        try {
          await widget.onReminder?.call(mode);
        } catch (error) {
          if (mounted) message(context, '任务已保存，部分提醒未启用：$error');
        }
      }
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) message(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> remove() async {
    final accepted = await confirm(context, '删除任务？', '任务将移入回收站，可以恢复。');
    if (!accepted || !mounted) return;
    try {
      await widget.controller.mutate((data, who) {
        if (who.scope != scope) throw const FormatException('账户已切换');
        deleteTask(data, widget.team, widget.task!.uid, who: who);
      });
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) message(context, error);
    }
  }

  Widget dropdown<T>(
    String label,
    T value,
    Map<T, String> choices,
    ValueChanged<T> change, {
    Key? key,
  }) => DropdownButtonFormField<T>(
    key: key,
    initialValue: choices.containsKey(value) ? value : choices.keys.first,
    isExpanded: true,
    decoration: InputDecoration(labelText: label),
    items: choices.entries
        .map(
          (entry) => DropdownMenuItem(
            value: entry.key,
            child: Text(entry.value, overflow: TextOverflow.ellipsis),
          ),
        )
        .toList(),
    onChanged: busy
        ? null
        : (value) {
            if (value != null) setState(() => change(value));
          },
  );

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    return Scaffold(
      appBar: AppBar(
        title: Text(task == null ? '新建任务' : '编辑任务'),
        actions: [
          if (task != null)
            IconButton(
              tooltip: '历史版本',
              icon: const Icon(Icons.history),
              onPressed: busy || attaching
                  ? null
                  : () async {
                      final restored = await Navigator.push<bool>(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              RecordHistoryPage(widget.controller, task.row),
                        ),
                      );
                      if (restored == true && context.mounted) {
                        Navigator.pop(context);
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
            TextFormField(
              controller: name,
              decoration: const InputDecoration(labelText: '任务名称'),
              maxLength: 500,
              validator: (value) =>
                  value?.trim().isNotEmpty == true ? null : '请输入任务名称',
            ),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.event_outlined),
                    title: const Text('开始日期'),
                    subtitle: Text(date == null ? '未安排' : dayLabel(date!)),
                    onTap: changeDate,
                    trailing: date == null
                        ? null
                        : IconButton(
                            tooltip: '清除日期',
                            icon: const Icon(Icons.close),
                            onPressed: () => setState(() {
                              date = null;
                              end = null;
                            }),
                          ),
                  ),
                  if (date != null) ...[
                    SwitchListTile(
                      title: const Text('全天'),
                      value: allDay,
                      onChanged: (value) => setState(() => allDay = value),
                    ),
                    if (!allDay)
                      ListTile(
                        title: const Text('开始时间'),
                        trailing: Text(time.format(context)),
                        onTap: changeTime,
                      ),
                    ListTile(
                      title: const Text('结束'),
                      onTap: changeEnd,
                      subtitle: Text(
                        end == null
                            ? '默认结束'
                            : '${dayLabel(end!)}${allDay ? '' : ' ${clock(end!)}'}',
                      ),
                      trailing: end == null
                          ? null
                          : IconButton(
                              tooltip: '重置结束时间',
                              icon: const Icon(Icons.close),
                              onPressed: () => setState(() => end = null),
                            ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),
            if (date != null) ...[
              dropdown('提醒时间', lead, {
                ...alarms,
                if (!alarms.containsKey(lead)) lead: '原提醒设置',
              }, (value) => lead = value),
              if (lead >= 0) ...[
                const SizedBox(height: 12),
                dropdown('提醒方式', mode, {
                  'both': '闹钟和系统推送',
                  'alarm': '闹钟',
                  'notification': '系统推送',
                }, (value) => mode = value),
              ],
              if (lead >= 0 && mode != 'notification')
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Text(
                    Theme.of(context).platform == TargetPlatform.iOS
                        ? '需要 iOS 26。响铃时可关闭或选择 10 分钟后再响。'
                        : '每次响铃 1 分钟，未关闭则每 10 分钟再次响铃。',
                  ),
                ),
              const SizedBox(height: 12),
              dropdown('重复', repeat, {
                for (final (index, label) in repeatNames.indexed) index: label,
              }, (value) => repeat = value),
              if (repeat > 0)
                Card(
                  child: ListTile(
                    title: const Text('重复结束日期'),
                    subtitle: Text(
                      repeatEnd == null ? '无限期' : dayLabel(repeatEnd!),
                    ),
                    onTap: () async {
                      final day = await pickDay(repeatEnd ?? date);
                      if (day != null && mounted) {
                        setState(() => repeatEnd = day);
                      }
                    },
                    trailing: repeatEnd == null
                        ? null
                        : IconButton(
                            tooltip: '改为无限期',
                            icon: const Icon(Icons.close),
                            onPressed: () => setState(() => repeatEnd = null),
                          ),
                  ),
                ),
              const SizedBox(height: 12),
            ],
            dropdown('优先级', rank, {
              for (final (index, label) in priorities.indexed) index + 1: label,
            }, (value) => rank = value),
            const SizedBox(height: 12),
            dropdown(
              '地点',
              place,
              {'': '未设置地点', for (final item in places) item.uid: item.name},
              (value) => place = value,
              key: ValueKey('place-$selectedTeam'),
            ),
            const SizedBox(height: 12),
            dropdown(
              '空间',
              selectedTeam,
              spaceOptions,
              changeSpace,
              key: ValueKey('space-$selectedTeam'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: tags,
              decoration: const InputDecoration(
                labelText: '标签',
                hintText: '用逗号分隔',
              ),
              maxLength: 1000,
            ),
            TextFormField(
              controller: remark,
              decoration: const InputDecoration(labelText: '备注'),
              minLines: 2,
              maxLines: 5,
              maxLength: 12000,
            ),
            TextFormField(
              controller: children,
              decoration: const InputDecoration(
                labelText: '子任务',
                hintText: '每行一个子任务',
              ),
              minLines: 2,
              maxLines: 6,
              maxLength: 8000,
            ),
            RecordAttachments(
              controller: widget.controller,
              team: sourceTeam,
              table: Tables.taskAttachment,
              parent: uid,
              draft: draft,
              files: mediaFiles,
              locked: busy,
              onState: (active, _) => setState(() => attaching = active),
            ),
            if (task != null) ...[
              ListenableBuilder(
                listenable: widget.controller,
                builder: (context, _) {
                  final current = findTask(
                    widget.controller.data,
                    widget.controller.identity,
                    widget.team,
                    task.uid,
                  );
                  if (current == null) return const SizedBox.shrink();
                  return Column(
                    children: [
                      for (final child in current.children)
                        CheckboxListTile(
                          title: Text(child.name),
                          value: current.childDone(
                            child,
                            widget.controller.identity.user,
                          ),
                          onChanged: moving
                              ? null
                              : (_) => widget.controller.mutate(
                                  (data, who) => toggleChild(
                                    data,
                                    who,
                                    widget.team,
                                    task.uid,
                                    child,
                                  ),
                                ),
                        ),
                    ],
                  );
                },
              ),
              TextFormField(
                controller: review,
                decoration: const InputDecoration(labelText: '复盘'),
                minLines: 2,
                maxLines: 5,
                maxLength: 12000,
              ),
              if (widget.controller.account != null) ...[
                OutlinedButton.icon(
                  icon: const Icon(Icons.chat_bubble_outline),
                  label: const Text('评论'),
                  onPressed: moving
                      ? null
                      : () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                CommentsPage(widget.controller, task),
                          ),
                        ),
                ),
                if (widget.team != widget.controller.identity.personal)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.people_outline),
                    label: const Text('参与人'),
                    onPressed: moving
                        ? null
                        : () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  AssigneesPage(widget.controller, task),
                            ),
                          ),
                  ),
              ],
              TextButton(
                onPressed: busy || attaching || moving ? null : remove,
                child: Text(
                  '删除任务',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
