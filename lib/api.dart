import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'domain.dart';

const defaultServer = String.fromEnvironment(
  'GXTODO_SERVER',
  defaultValue: 'https://tudosrv.woslx.com',
);
const developmentHttp = bool.fromEnvironment('GXTODO_DEV_HTTP');

class ApiFailure implements Exception {
  const ApiFailure(this.message, [this.status = '1']);
  final String message, status;
  @override
  String toString() => message;
}

String serverOrigin(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.hasPort && (uri.port <= 0 || uri.port > 65535))) {
    throw const FormatException('请输入服务端地址，例如 https://todo.example.com');
  }
  final local = {'localhost', '127.0.0.1', '10.0.2.2'}.contains(uri.host);
  if (uri.scheme != 'https' &&
      !(developmentHttp && !kIsWeb && local && uri.scheme == 'http')) {
    throw const FormatException('服务端地址必须使用 HTTPS');
  }
  return uri.origin;
}

class Account {
  const Account({
    required this.server,
    required this.user,
    required this.login,
    required this.personal,
    required this.token,
    required this.email,
    required this.nickname,
  });

  factory Account.fromJson(Fields value) => Account(
    server: text(value['server']),
    user: integer(value['user']),
    login: integer(value['login']),
    personal: integer(value['personal']),
    token: text(value['token']),
    email: text(value['email']),
    nickname: text(value['nickname']),
  );

  final String server, token, email, nickname;
  final int user, login, personal;
  Identity get identity => Identity('$server/$user', user, personal);

  Fields toJson() => {
    'server': server,
    'user': user,
    'login': login,
    'personal': personal,
    'token': token,
    'email': email,
    'nickname': nickname,
  };

  Account withProfile(Fields profile) => Account.fromJson({
    ...toJson(),
    'email': profile['email'],
    'nickname': profile['nickname'],
  });
}

class TodoApi {
  const TodoApi(this.server, [this.account]);
  final String server;
  final Account? account;

  Map<String, dynamic> get sessionFields {
    final signedIn = account;
    if (signedIn == null) throw const ApiFailure('请先登录后保存图片或录音');
    return {
      'user_id': signedIn.user,
      'login_id': signedIn.login,
      'token': signedIn.token,
    };
  }

  Future<Fields> uploadMedia(
    File file,
    int team,
    String note,
    String kind,
    String name, {
    String? clientId,
    String? checksum,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${serverOrigin(server)}/api/v7/media/upload'),
    )..followRedirects = false;
    request.fields.addAll({
      for (final entry in sessionFields.entries) entry.key: '${entry.value}',
      'team_id': '$team',
      'note_id': note,
      'kind': kind,
      'client_id': ?clientId,
      'sha256': ?checksum,
    });
    request.files.add(
      await http.MultipartFile.fromPath('file', file.path, filename: name),
    );
    final client = http.Client();
    try {
      final response = await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(minutes: 3));
      final reply = fields(jsonDecode(utf8.decode(response.bodyBytes)));
      if (response.statusCode != 200 || text(reply['status']) != '0') {
        throw ApiFailure(
          text(reply['message']).isEmpty
              ? '附件上传失败，请重试'
              : text(reply['message']),
        );
      }
      return fields(reply['data']);
    } finally {
      client.close();
    }
  }

  Future<void> downloadMedia(String id, File target) async {
    final request =
        http.Request(
            'POST',
            Uri.parse('${serverOrigin(server)}/api/v7/media/read'),
          )
          ..followRedirects = false
          ..headers['Content-Type'] = 'application/json'
          ..body = jsonEncode({...sessionFields, 'id': id});
    final client = http.Client();
    IOSink? sink;
    try {
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200 ||
          (response.headers['content-type'] ?? '').startsWith(
            'application/json',
          )) {
        throw const ApiFailure('附件读取失败，请检查登录状态和网络后重试');
      }
      sink = target.openWrite();
      var size = 0;
      await for (final bytes in response.stream.timeout(
        const Duration(seconds: 60),
      )) {
        size += bytes.length;
        if (size > 100 * 1024 * 1024) throw const ApiFailure('附件超过 100 MB');
        sink.add(bytes);
      }
      await sink.flush();
    } finally {
      await sink?.close();
      client.close();
    }
  }

  Future<Fields> call(
    String route, {
    String method = 'POST',
    Fields values = const {},
  }) async {
    if (server.isEmpty) throw const ApiFailure('请先设置服务端地址');
    final restMethod = method != 'POST';
    final session = account;
    final body = <String, dynamic>{
      ...values,
      if (session != null) ...{
        'user_id': session.user,
        'login_id': session.login,
        'token': session.token,
      },
      if (restMethod) '_method': method,
    };
    try {
      final uri = Uri.parse('${serverOrigin(server)}/api/v7$route');
      final client = http.Client();
      try {
        final request = http.Request('POST', uri)
          ..followRedirects = false
          ..headers['Content-Type'] = 'application/json; charset=utf-8'
          ..body = jsonEncode(body);
        final response = await client
            .send(request)
            .then(http.Response.fromStream)
            .timeout(const Duration(seconds: 16));
        if (response.statusCode != 200) {
          throw ApiFailure('服务端返回 HTTP ${response.statusCode}');
        }
        final value = fields(jsonDecode(utf8.decode(response.bodyBytes)));
        if (text(value['status']) != '0') {
          throw ApiFailure(
            text(value['message']).isEmpty ? '服务端请求失败' : text(value['message']),
            text(value['status']),
          );
        }
        return value;
      } finally {
        client.close();
      }
    } on TimeoutException {
      throw const ApiFailure('连接超时，请检查服务端地址');
    } on http.ClientException {
      throw const ApiFailure('无法连接服务端');
    }
  }
}

class SignedIn {
  const SignedIn(this.account, this.spaces);
  final Account account;
  final List<Space> spaces;
}

Future<SignedIn> signIn(
  String server,
  String email,
  String password,
  String device,
  bool register,
) async {
  final response = await TodoApi(server).call(
    register ? '/user/base' : '/user/login',
    values: {'email': email, 'password': password, 'dev_id': device, 'p': 'A'},
  );
  final spaces = objects(response['teamData'])
      .map(Space.fromJson)
      .where((space) => space.id > 0)
      .toList();
  final personal = spaces.where((space) => space.type == 1).firstOrNull;
  final profile = fields(response['data']);
  final account = Account(
    server: server,
    user: integer(response['user_id']),
    login: integer(response['login_id']),
    personal: personal?.id ?? 0,
    token: text(response['token']),
    email: text(profile['email']),
    nickname: text(profile['nickname']),
  );
  if (account.personal <= 0 ||
      account.user <= 0 ||
      account.login <= 0 ||
      account.token.isEmpty) {
    throw const ApiFailure('服务端登录响应不完整');
  }
  return SignedIn(account, spaces);
}
