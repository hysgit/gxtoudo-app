import 'dart:convert';

import 'package:gxtodo/domain.dart';
import 'package:gxtodo/repository.dart';

class MemoryRepository implements LocalRepository {
  final workspaces = <String, String>{};
  final settings = <String, String>{};

  WorkspaceData _read(String scope) => workspaces.containsKey(scope)
      ? WorkspaceData.fromJson(fields(jsonDecode(workspaces[scope]!)))
      : WorkspaceData();

  @override
  Future<WorkspaceData> read(String scope) async => _read(scope);

  @override
  Future<WorkspaceData> change(
    String scope,
    void Function(WorkspaceData) action,
  ) async {
    final data = _read(scope);
    action(data);
    workspaces[scope] = jsonEncode(data.toJson());
    return data;
  }

  @override
  Future<String?> setting(String key) async => settings[key];

  @override
  Future<void> setSetting(String key, String? value) async {
    if (value == null) {
      settings.remove(key);
    } else {
      settings[key] = value;
    }
  }
}
