import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'domain.dart';

abstract interface class LocalRepository {
  Future<WorkspaceData> read(String scope);
  Future<WorkspaceData> change(
    String scope,
    void Function(WorkspaceData data) action,
  );
  Future<String?> setting(String key);
  Future<void> setSetting(String key, String? value);
}

class SqliteRepository implements LocalRepository {
  SqliteRepository();

  late final Future<Database> _db = _open();

  Future<Database> _open() async {
    return openDatabase(
      '${await getDatabasesPath()}/gxtodo.db',
      version: 1,
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE workspace(scope TEXT PRIMARY KEY, payload TEXT NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE setting(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
      },
    );
  }

  Future<WorkspaceData> _read(DatabaseExecutor db, String scope) async {
    final rows = await db.query(
      'workspace',
      columns: ['payload'],
      where: 'scope=?',
      whereArgs: [scope],
      limit: 1,
    );
    return rows.isEmpty
        ? WorkspaceData()
        : WorkspaceData.fromJson(
            fields(jsonDecode(rows.single['payload'] as String)),
          );
  }

  @override
  Future<WorkspaceData> read(String scope) async => _read(await _db, scope);

  @override
  Future<WorkspaceData> change(
    String scope,
    void Function(WorkspaceData) action,
  ) async {
    return (await _db).transaction((txn) async {
      final current = await _read(txn, scope);
      action(current);
      await txn.insert('workspace', {
        'scope': scope,
        'payload': jsonEncode(current.toJson()),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return current;
    });
  }

  @override
  Future<String?> setting(String key) async {
    final result = await (await _db).query(
      'setting',
      columns: ['value'],
      where: 'key=?',
      whereArgs: [key],
      limit: 1,
    );
    return result.isEmpty ? null : result.single['value'] as String;
  }

  @override
  Future<void> setSetting(String key, String? value) async {
    final db = await _db;
    if (value == null) {
      await db.delete('setting', where: 'key=?', whereArgs: [key]);
    } else {
      await db.insert('setting', {
        'key': key,
        'value': value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }
}
