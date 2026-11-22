import 'dart:math';

import 'domain.dart';
import 'record_versions.dart';
import 'schedule.dart';

class Task {
  Task(this.row, List<Item> related, int user)
    : schedule = related
          .where((item) => item.table == Tables.schedule)
          .firstOrNull,
      repeat = related.where((item) => item.table == Tables.repeat).firstOrNull,
      alert = related
          .where(
            (item) =>
                item.table == Tables.alert &&
                integer(item.data['user_id']) == user,
          )
          .firstOrNull,
      children = (related.where((item) => item.table == Tables.subtask).toList()
        ..sort(
          (a, b) =>
              integer(a.data['sequence'])
                  .compareTo(integer(b.data['sequence'])),
        )),
      tags = related.where((item) => item.table == Tables.taskTag).toList(),
      checks = related.where((item) => item.table == Tables.check).toList(),
      subchecks = related
          .where((item) => item.table == Tables.subcheck)
          .toList(),
      members = related.where((item) => item.table == Tables.assignee).toList(),
      details = related.where((item) => item.table == Tables.details).toList();

  final Item row;
  final Item? schedule, repeat, alert;
  final List<Item> children, tags, checks, subchecks, members, details;

  String get uid => row.uid;
  String get name => row.name;
  int get team => row.team;
  int get rank => integer(row.data['rank'], 1).clamp(1, 4);
  int get start => integer(schedule?.data['start_at']);
  int get end => integer(schedule?.data['end_at']);
  bool get allDay => integer(schedule?.data['is_all_day']) == 1;
  String get project => text(row.data['project_id']);
  String get place => text(row.data['position_id']);
  String detail(int type) => text(
    details
        .where((item) => integer(item.data['type']) == type)
        .firstOrNull
        ?.data['content'],
  );

  int on(DateTime day) => occurs(start, repeat?.data, day);

  int listTime(DateTime today) {
    if (repeat == null || start == 0) return start;
    final first = dayOnly(localTime(start));
    final base = first.isAfter(today) ? first : today;
    for (var i = 0; i < 370; i++) {
      final value = on(addDays(base, i));
      if (value > 0) return value;
    }
    return start;
  }

  Item? check(int user, int occurrence) => checks
      .where(
        (item) =>
            integer(item.data['user_id']) == user &&
            (repeat == null || integer(item.data['start_at']) == occurrence),
      )
      .firstOrNull;

  bool done(int user, int occurrence) =>
      integer(check(user, occurrence)?.data['status']) == 1;

  Item? childCheck(Item child, int user) => subchecks
      .where(
        (item) =>
            integer(item.data['user_id']) == user &&
            text(item.data['child_task_id']) == child.uid,
      )
      .firstOrNull;

  bool childDone(Item child, int user) =>
      integer(childCheck(child, user)?.data['status']) == 1;
}

class TaskChanges {
  const TaskChanges({
    required this.name,
    required this.rank,
    required this.project,
    required this.place,
    required this.start,
    required this.end,
    required this.allDay,
    required this.repeat,
    required this.repeatEnd,
    required this.alert,
    required this.remark,
    required this.review,
    required this.tags,
    required this.children,
    this.reminderMode = 'both',
  });
  final String name, project, place, remark, review;
  final int rank, start, end, repeat, repeatEnd, alert;
  final bool allDay;
  final List<String> tags, children;
  final String reminderMode;
}

List<Task> taskList(WorkspaceData data, Identity who, int team) {
  final parents = <Item>[];
  final related = <String, List<Item>>{};
  for (final item in data.items.values) {
    if (item.team != team || item.removed) continue;
    if (item.table == Tables.task) {
      parents.add(item);
    } else {
      final parent = text(item.data['task_id']);
      if (parent.isNotEmpty) (related[parent] ??= []).add(item);
    }
  }
  return parents
      .map((row) => Task(row, related[row.uid] ?? [], who.user))
      .toList();
}

int compareTaskEntries((Task, int) a, (Task, int) b, int user) {
  final aDone = a.$1.done(user, a.$2), bDone = b.$1.done(user, b.$2);
  if (aDone != bDone) return aDone ? 1 : -1;
  if (aDone) {
    int completed((Task, int) entry) {
      final check = entry.$1.check(user, entry.$2);
      return integer(check?.data['check_at'], (check?.edited ?? 0) ~/ 1000);
    }

    final order = completed(b).compareTo(completed(a));
    if (order != 0) return order;
  }
  final order = (a.$2 == 0 ? 1 << 62 : a.$2).compareTo(
    b.$2 == 0 ? 1 << 62 : b.$2,
  );
  if (order != 0) return order;
  if (!aDone) {
    final priority = b.$1.rank.compareTo(a.$1.rank);
    if (priority != 0) return priority;
  }
  return a.$1.uid.compareTo(b.$1.uid);
}

Task? findTask(WorkspaceData data, Identity who, int team, String id) =>
    taskList(data, who, team).where((task) => task.uid == id).firstOrNull;

String saveTask(
  WorkspaceData data,
  Identity who,
  int team,
  String? editing,
  TaskChanges edit, {
  int? targetTeam,
  Set<int> targetMembers = const <int>{},
  String? newUid,
  List<Fields> attachments = const [],
  Map<String, Fields> media = const {},
  Set<String> removedAttachments = const {},
  String versionAction = '保存',
}) {
  final destination = targetTeam ?? team;
  final sourceTeam = team;
  final source = editing == null
      ? null
      : findTask(data, who, sourceTeam, editing);
  if (editing != null && source == null) throw StateError('任务已删除');
  final moving = source != null && sourceTeam != destination;
  final targetId = moving
      ? newUid ?? newId(Tables.task)
      : editing ?? newUid ?? newId(Tables.task);
  if (source != null) captureTask(data, who, source, onlyIfMissing: true);
  if (source != null && sourceTeam != destination) {
    final related = [
      source.row,
      if (source.schedule != null) source.schedule!,
      if (source.repeat != null) source.repeat!,
      if (source.alert != null) source.alert!,
      ...source.children,
      ...source.tags,
      ...source.checks,
      ...source.subchecks,
      ...source.members,
      ...source.details,
    ];
    final movedIds = {for (final row in related) row.uid: newId(row.table)}
      ..[source.row.uid] = targetId;
    const memberOwnedTables = {Tables.check, Tables.subcheck, Tables.assignee};
    for (final row in related) {
      final owner = integer(row.data['user_id'], who.user);
      if (row.table == Tables.alert && owner != who.user) continue;
      if (memberOwnedTables.contains(row.table) &&
          !targetMembers.contains(owner)) {
        continue;
      }
      final copied = {...row.data};
      for (final field in ['task_id', 'schedule_id', 'child_task_id']) {
        final relatedId = movedIds[text(copied[field])];
        if (relatedId != null) copied[field] = relatedId;
      }
      data.save(who, destination, row.table, movedIds[row.uid]!, {
        ...copied,
        'user_id': memberOwnedTables.contains(row.table) ? owner : who.user,
      });
    }
  }
  final id = targetId;
  final existing = editing == null
      ? null
      : findTask(data, who, destination, id);
  if (editing != null && existing == null) throw StateError('任务已删除');
  final schedule = existing?.schedule?.uid ?? newId(Tables.schedule);
  data.save(who, destination, Tables.task, id, {
    'name': edit.name,
    'rank': edit.rank,
    'privacy': destination == who.personal ? 6720 : 6728,
    'project_id': edit.project,
    'position_id': edit.place,
  });
  if (existing == null) {
    data.save(who, destination, Tables.assignee, newId(Tables.assignee), {
      'task_id': id,
      'role': 7680,
      'sequence': 0,
      'status': 0,
    });
  }
  data.save(who, destination, Tables.schedule, schedule, {
    'task_id': id,
    'start_at': edit.start,
    'end_at': edit.end,
    'is_all_day': edit.allDay ? 1 : 0,
    'is_repeat': edit.repeat == 0 ? 0 : 1,
  });
  if (edit.repeat > 0 && edit.start > 0) {
    data.save(
      who,
      destination,
      Tables.repeat,
      existing?.repeat?.uid ?? newId(Tables.repeat),
      {
        ...recurrence(edit.repeat, edit.start, edit.repeatEnd),
        'task_id': id,
        'schedule_id': schedule,
      },
    );
  } else {
    data.remove(existing?.repeat);
  }
  if (edit.alert >= 0 && edit.start > 0) {
    data.save(
      who,
      destination,
      Tables.alert,
      existing?.alert?.uid ?? newId(Tables.alert),
      {
        'task_id': id,
        'schedule_id': schedule,
        'alert_time': edit.alert,
        'reminder_mode': edit.reminderMode,
      },
    );
  } else {
    data.remove(existing?.alert);
  }
  for (final entry in {1: edit.review, 2: edit.remark}.entries) {
    final detail = existing?.details
        .where((item) => integer(item.data['type']) == entry.key)
        .firstOrNull;
    if (entry.value.isEmpty) {
      data.remove(detail);
    } else {
      data.save(
        who,
        destination,
        Tables.details,
        detail?.uid ?? newId(Tables.details),
        {'task_id': id, 'type': entry.key, 'content': entry.value},
      );
    }
  }
  final children = [...?existing?.children];
  for (final (index, name) in edit.children.indexed) {
    final previous = children.where((child) => child.name == name).firstOrNull;
    if (previous != null) children.remove(previous);
    data.save(
      who,
      destination,
      Tables.subtask,
      previous?.uid ?? newId(Tables.subtask),
      {'task_id': id, 'name': name, 'sequence': index},
    );
  }
  for (final removed in children) {
    data.remove(removed);
    for (final check in existing!.subchecks.where(
      (item) => item.data['child_task_id'] == removed.uid,
    )) {
      data.remove(check);
    }
  }
  final tags = data
      .list(destination, Tables.tag)
      .map((item) => item.name)
      .toSet();
  final mappings = {
    for (final item in existing?.tags ?? <Item>[])
      text(item.data['tag_name']): item,
  };
  for (final name in edit.tags.toSet()) {
    if (tags.add(name)) {
      data.save(who, destination, Tables.tag, newId(Tables.tag), {
        'name': name,
      });
    }
    if (mappings.remove(name) == null) {
      data.save(who, destination, Tables.taskTag, newId(Tables.taskTag), {
        'task_id': id,
        'tag_name': name,
      });
    }
  }
  for (final removed in mappings.values) {
    data.remove(removed);
  }
  if (editing != null && sourceTeam != destination) {
    deleteTask(data, sourceTeam, editing, who: who, action: '移出空间');
  }
  saveRecordAttachments(
    data,
    who,
    destination,
    Tables.taskAttachment,
    id,
    attachments,
    media,
    removedAttachments,
  );
  if (versionAction.isNotEmpty) {
    captureTask(
      data,
      who,
      findTask(data, who, destination, id)!,
      action: versionAction,
    );
  }
  return id;
}

void toggleTask(
  WorkspaceData data,
  Identity who,
  int team,
  String id,
  int occurrence,
) {
  final task = findTask(data, who, team, id);
  if (task?.schedule == null) return;
  captureTask(data, who, task!, onlyIfMissing: true);
  final check = task.check(who.user, occurrence);
  if (integer(check?.data['status']) == 1) {
    data.remove(check);
  } else {
    final now = seconds(DateTime.now());
    data.save(who, team, Tables.check, check?.uid ?? newId(Tables.check), {
      'task_id': id,
      'schedule_id': task.schedule!.uid,
      'start_at': occurrence,
      'begin_time': occurrence,
      'check_at': now,
      'cost_time': occurrence > 0 ? max(0, now - occurrence) : 0,
      'status': 1,
      'role': 7680,
    });
  }
  captureTask(
    data,
    who,
    findTask(data, who, team, id)!,
    action: integer(check?.data['status']) == 1 ? '取消完成' : '完成任务',
  );
}

void toggleChild(
  WorkspaceData data,
  Identity who,
  int team,
  String id,
  Item child,
) {
  final task = findTask(data, who, team, id);
  final previous = task?.childCheck(child, who.user);
  if (task == null || data.get(team, Tables.subtask, child.uid) == null) return;
  captureTask(data, who, task, onlyIfMissing: true);
  if (integer(previous?.data['status']) == 1) {
    data.remove(previous);
  } else {
    data.save(
      who,
      team,
      Tables.subcheck,
      previous?.uid ?? newId(Tables.subcheck),
      {'task_id': id, 'child_task_id': child.uid, 'status': 1},
    );
  }
  captureTask(
    data,
    who,
    findTask(data, who, team, id)!,
    action: integer(previous?.data['status']) == 1 ? '取消完成子任务' : '完成子任务',
  );
}

void deleteTask(
  WorkspaceData data,
  int team,
  String id, {
  Identity? who,
  String action = '删除',
}) {
  final row = data.get(team, Tables.task, id);
  if (row == null) return;
  if (who != null) {
    final task = findTask(data, who, team, id)!;
    captureTask(data, who, task, onlyIfMissing: true);
    captureTask(data, who, task, action: action);
  }
  data.remove(row);
}

String reminderMode(Item? alert) => switch (alert?.data['reminder_mode']) {
  'alarm' => 'alarm',
  'notification' => 'notification',
  _ => 'both',
};

void captureTask(
  WorkspaceData data,
  Identity who,
  Task task, {
  bool onlyIfMissing = false,
  String action = '保存',
}) {
  final personal = task.team == who.personal;
  captureVersion(
    data,
    who,
    task.team,
    Tables.task,
    task.uid,
    {
      'name': task.name,
      'rank': task.rank,
      'project': task.project,
      'place': task.place,
      'start': task.start,
      'end': task.end,
      'allDay': task.allDay,
      'repeat': repeatKind(task.repeat?.data),
      'repeatEnd': integer(task.repeat?.data['repeat_end']),
      if (personal) 'alert': integer(task.alert?.data['alert_time'], -1),
      if (personal) 'reminderMode': reminderMode(task.alert),
      'remark': task.detail(2),
      'review': task.detail(1),
      'tags': task.tags.map((item) => text(item.data['tag_name'])).toList()
        ..sort(),
      'children': task.children.map((row) => row.name).toList(),
      if (personal)
        'completedChildren': [
          for (final (index, child) in task.children.indexed)
            if (task.childDone(child, who.user)) index,
        ],
      if (personal)
        'checks': [
          for (final row in task.checks.where(
            (row) =>
                integer(row.data['user_id']) == who.user &&
                integer(row.data['status']) == 1,
          ))
            [integer(row.data['start_at']), integer(row.data['check_at'])],
        ],
      'attachments': attachmentIds(
        data,
        task.team,
        Tables.taskAttachment,
        task.uid,
      ),
    },
    onlyIfMissing: onlyIfMissing,
    action: action,
  );
}

void revertTask(WorkspaceData data, Identity who, Item row, Fields snapshot) {
  final current = findTask(data, who, row.team, row.uid);
  if (current == null) throw const FormatException('任务已删除');
  if (text(snapshot['name']).isEmpty) throw const FormatException('此任务版本不完整');
  final personal = row.team == who.personal;
  saveTask(
    data,
    who,
    row.team,
    row.uid,
    TaskChanges(
      name: text(snapshot['name']),
      rank: integer(snapshot['rank'], 1),
      project: text(snapshot['project']),
      place: text(snapshot['place']),
      start: integer(snapshot['start']),
      end: integer(snapshot['end']),
      allDay: snapshot['allDay'] == true,
      repeat: integer(snapshot['repeat']),
      repeatEnd: integer(snapshot['repeatEnd']),
      alert: personal
          ? integer(snapshot['alert'], -1)
          : integer(current.alert?.data['alert_time'], -1),
      reminderMode: personal
          ? text(snapshot['reminderMode'])
          : reminderMode(current.alert),
      remark: text(snapshot['remark']),
      review: text(snapshot['review']),
      tags: (snapshot['tags'] as List).cast<String>(),
      children: (snapshot['children'] as List).cast<String>(),
    ),
    versionAction: '',
  );
  restoreAttachmentIds(
    data,
    who,
    row.team,
    Tables.taskAttachment,
    row.uid,
    snapshot['attachments'] as List<Object?>,
  );
  final updated = findTask(data, who, row.team, row.uid)!;
  if (personal) {
    for (final check in updated.checks.where(
      (row) => integer(row.data['user_id']) == who.user,
    )) {
      data.remove(check);
    }
    for (final entry in (snapshot['checks'] as List).cast<List>()) {
      final start = integer(entry[0]), checked = integer(entry[1]);
      data.save(who, row.team, Tables.check, newId(Tables.check), {
        'task_id': row.uid,
        'schedule_id': updated.schedule!.uid,
        'start_at': start,
        'begin_time': start,
        'check_at': checked,
        'cost_time': start > 0 ? max(0, checked - start) : 0,
        'status': 1,
        'role': 7680,
      });
    }
    final done = snapshot['completedChildren'] as List;
    for (final (index, child) in updated.children.indexed) {
      final existing = updated.childCheck(child, who.user);
      if (done.contains(index)) {
        data.save(
          who,
          row.team,
          Tables.subcheck,
          existing?.uid ?? newId(Tables.subcheck),
          {'task_id': row.uid, 'child_task_id': child.uid, 'status': 1},
        );
      } else {
        data.remove(existing);
      }
    }
  }
  captureTask(
    data,
    who,
    findTask(data, who, row.team, row.uid)!,
    action: '还原版本',
  );
}
