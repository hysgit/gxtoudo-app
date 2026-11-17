import 'dart:math';

import 'domain.dart';
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
  });
  final String name, project, place, remark, review;
  final int rank, start, end, repeat, repeatEnd, alert;
  final bool allDay;
  final List<String> tags, children;
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

Task? findTask(WorkspaceData data, Identity who, int team, String id) =>
    taskList(data, who, team).where((task) => task.uid == id).firstOrNull;

void saveTask(
  WorkspaceData data,
  Identity who,
  int team,
  String? editing,
  TaskChanges edit,
) {
  final existing = editing == null ? null : findTask(data, who, team, editing);
  if (editing != null && existing == null) throw StateError('任务已删除');
  final id = editing ?? newId(Tables.task);
  final schedule = existing?.schedule?.uid ?? newId(Tables.schedule);
  data.save(who, team, Tables.task, id, {
    'name': edit.name,
    'rank': edit.rank,
    'privacy': team == who.personal ? 6720 : 6728,
    'project_id': edit.project,
    'position_id': edit.place,
  });
  if (existing == null) {
    data.save(who, team, Tables.assignee, newId(Tables.assignee), {
      'task_id': id,
      'role': 7680,
      'sequence': 0,
      'status': 0,
    });
  }
  data.save(who, team, Tables.schedule, schedule, {
    'task_id': id,
    'start_at': edit.start,
    'end_at': edit.end,
    'is_all_day': edit.allDay ? 1 : 0,
    'is_repeat': edit.repeat == 0 ? 0 : 1,
  });
  if (edit.repeat > 0 && edit.start > 0) {
    data.save(
      who,
      team,
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
      team,
      Tables.alert,
      existing?.alert?.uid ?? newId(Tables.alert),
      {'task_id': id, 'schedule_id': schedule, 'alert_time': edit.alert},
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
        team,
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
      team,
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
  final tags = data.list(team, Tables.tag).map((item) => item.name).toSet();
  final mappings = {
    for (final item in existing?.tags ?? <Item>[])
      text(item.data['tag_name']): item,
  };
  for (final name in edit.tags.toSet()) {
    if (tags.add(name)) {
      data.save(who, team, Tables.tag, newId(Tables.tag), {'name': name});
    }
    if (mappings.remove(name) == null) {
      data.save(who, team, Tables.taskTag, newId(Tables.taskTag), {
        'task_id': id,
        'tag_name': name,
      });
    }
  }
  for (final removed in mappings.values) {
    data.remove(removed);
  }
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
  final check = task!.check(who.user, occurrence);
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
}

void deleteTask(WorkspaceData data, int team, String id) {
  data.remove(data.get(team, Tables.task, id));
  for (final row in data.items.values.toList()) {
    if (row.team == team && row.data['task_id'] == id) data.remove(row);
  }
}
