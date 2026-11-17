import 'dart:math';

typedef Fields = Map<String, dynamic>;

abstract final class Tables {
  static const note = 49,
      tag = 59,
      place = 69,
      check = 76,
      alert = 77,
      repeat = 78,
      schedule = 79,
      subcheck = 83,
      taskTag = 84,
      details = 86,
      subtask = 87,
      assignee = 88,
      task = 89,
      projectMember = 98,
      project = 99;
  static const all = {
    note,
    tag,
    place,
    check,
    alert,
    repeat,
    schedule,
    subcheck,
    taskTag,
    details,
    subtask,
    assignee,
    task,
    projectMember,
    project,
  };
}

String text(Object? value) => value?.toString() ?? '';
int integer(Object? value, [int fallback = 0]) =>
    value is int ? value : int.tryParse(text(value)) ?? fallback;

Map<String, dynamic> fields(Object? source) =>
    source is Map<String, dynamic> ? source : <String, dynamic>{};

Iterable<Fields> objects(Object? source) =>
    source is List ? source.whereType<Fields>() : const <Fields>[];

final _random = Random.secure();

String newId(Object type) =>
    '$type-${List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

class Identity {
  const Identity(this.scope, this.user, this.personal);
  static const guest = Identity('guest', 0, -1);

  final String scope;
  final int user;
  final int personal;
}

class Space {
  const Space(this.id, this.name, this.type, this.owner, [this.capacity = 1]);

  factory Space.fromJson(Fields data) => Space(
    integer(data['id']),
    text(data['name']),
    integer(data['type']),
    integer(data['user_id']),
    integer(data['total_size'], 1),
  );

  static const guest = Space(-1, '个人空间', 1, 0);
  final int id, type, owner, capacity;
  final String name;

  Fields toJson() => {
    'id': id,
    'name': name,
    'type': type,
    'user_id': owner,
    'total_size': capacity,
  };
}

String itemKey(int team, int table, String uid) => '$team:$table:$uid';

class Item {
  const Item({
    required this.table,
    required this.team,
    required this.uid,
    required this.data,
    this.revision = 0,
    this.edited = 0,
    this.pending = 0,
    this.removed = false,
  });

  factory Item.fromJson(Fields value) => Item(
    table: integer(value['table']),
    team: integer(value['team']),
    uid: text(value['uid']),
    data: fields(value['data']),
    revision: integer(value['revision']),
    edited: integer(value['edited']),
    pending: integer(value['pending']),
    removed: value['removed'] == true,
  );

  final int table, team, revision, edited, pending;
  final String uid;
  final bool removed;
  final Fields data;
  String get key => itemKey(team, table, uid);
  String get name => text(data['name']);

  Item copy({int? revision, int? edited, int? pending, bool? removed}) => Item(
    table: table,
    team: team,
    uid: uid,
    data: data,
    revision: revision ?? this.revision,
    edited: edited ?? this.edited,
    pending: pending ?? this.pending,
    removed: removed ?? this.removed,
  );

  Fields toJson() => {
    'table': table,
    'team': team,
    'uid': uid,
    'revision': revision,
    'edited': edited,
    'pending': pending,
    'removed': removed,
    'data': data,
  };

  Fields toUpload() => {
    'table': table,
    'mode': pending,
    'edit_time': edited,
    'entropy': revision,
    'data': removed
        ? {'uid': uid, 'team_id': team, 'user_id': data['user_id']}
        : data,
  };
}

class WorkspaceData {
  WorkspaceData({
    Map<String, Item>? items,
    Map<String, int>? cursors,
    List<Space>? spaces,
  }) : items = items ?? {},
       cursors = cursors ?? {},
       spaces = spaces ?? [];

  factory WorkspaceData.fromJson(Fields value) {
    final rows = objects(value['items']).map(Item.fromJson);
    return WorkspaceData(
      items: {for (final item in rows) item.key: item},
      cursors: fields(value['cursors'])
          .map((key, value) => MapEntry(key, integer(value))),
      spaces: objects(value['spaces']).map(Space.fromJson).toList(),
    );
  }

  final Map<String, Item> items;
  final Map<String, int> cursors;
  List<Space> spaces;

  Fields toJson() => {
    'items': items.values.map((item) => item.toJson()).toList(),
    'cursors': cursors,
    'spaces': spaces.map((space) => space.toJson()).toList(),
  };

  Iterable<Item> list(int team, int table) => items.values.where(
    (item) => item.team == team && item.table == table && !item.removed,
  );

  Item? get(int team, int table, String id) {
    final row = items[itemKey(team, table, id)];
    return row?.removed == true ? null : row;
  }

  Item save(Identity who, int team, int table, String uid, Fields changes) {
    final key = itemKey(team, table, uid);
    final previous = items[key];
    final edited = max(
      DateTime.now().millisecondsSinceEpoch,
      (previous?.edited ?? 0) + 1,
    );
    final stamp = DateTime.fromMillisecondsSinceEpoch(
      edited,
      isUtc: true,
    ).toIso8601String().substring(0, 19).replaceFirst('T', ' ');
    final data = <String, dynamic>{
      'created_at': stamp,
      ...?previous?.data,
      ...changes,
      'uid': uid,
      'team_id': team,
      'user_id': previous?.data['user_id'] ?? changes['user_id'] ?? who.user,
    };
    if (previous != null &&
        !previous.removed &&
        data.entries.every(
          (entry) => text(previous.data[entry.key]) == text(entry.value),
        )) {
      return previous;
    }
    data['updated_at'] = stamp;
    return items[key] = Item(
      table: table,
      team: team,
      uid: uid,
      data: data,
      edited: edited,
      revision: previous?.revision ?? 0,
      pending: previous == null || previous.pending == 1 ? 1 : 2,
    );
  }

  void remove(Item? row) {
    if (row == null) return;
    final current = items[row.key];
    if (current == null || current.removed) return;
    items[row.key] = current.copy(
      edited: max(DateTime.now().millisecondsSinceEpoch, current.edited + 1),
      pending: 3,
      removed: true,
    );
  }

  Fields exportPersonal(Identity who) => {
    'format': 'gxtodo-personal-v1',
    'items': items.values
        .where((item) => !item.removed && item.team == who.personal)
        .map((item) => {'table': item.table, 'data': item.data})
        .toList(),
  };

  int importPersonal(Identity who, Fields backup) {
    final entries = backup['items'];
    if (backup['format'] != 'gxtodo-personal-v1' ||
        entries is! List ||
        entries.length > 40000) {
      throw const FormatException('无法读取此备份');
    }
    var added = 0;
    for (final raw in entries) {
      final row = fields(raw);
      final table = integer(row['table']);
      final data = {...fields(row['data'])};
      final uid = data['uid'];
      if (!Tables.all.contains(table) ||
          uid is! String ||
          uid.isEmpty ||
          uid.length > 256 ||
          data.values.any(
            (value) => value is! String && (value is! num || !value.isFinite),
          )) {
        throw const FormatException('备份包含无效记录');
      }
      if (items.containsKey(itemKey(who.personal, table, uid))) continue;
      data.remove('entropy');
      save(who, who.personal, table, uid, {...data, 'user_id': who.user});
      added++;
    }
    return added;
  }
}
