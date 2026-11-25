import 'dart:convert';

import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gxtodo/ai_page.dart';
import 'package:gxtodo/api.dart';
import 'package:gxtodo/controller.dart';
import 'package:gxtodo/domain.dart';
import 'package:gxtodo/home.dart';
import 'package:material_ui/material_ui.dart';

import 'memory_repository.dart';

void main() {
  testWidgets('汇总隐藏账单，只有明确请求的账单可点开，Markdown 正常排版', (tester) async {
    const sample = '## 费用汇总\n\n共 **5 笔，合计 115 元**。\n\n- 公交费用';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiAnswer({
            'answer': sample,
            'refs': jsonEncode([
              {'table': 51, 'name': '自动附带的账单'},
              {'table': 51, 'name': '明确请求的账单', 'explicit_bill_detail': true},
            ]),
          }, openRecord: (_) {}),
        ),
      ),
    );
    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.text('费用汇总', findRichText: true), findsOneWidget);
    expect(find.textContaining('**', findRichText: true), findsNothing);
    expect(find.text('自动附带的账单'), findsNothing);
    expect(find.text('明确请求的账单'), findsOneWidget);
  });

  testWidgets('进入或切回 AI 对话时显示长回复的末尾', (tester) async {
    final controller = _ChatController();
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.account = _ChatApi.user;
    controller.team = _ChatApi.user.personal;
    await tester.pumpWidget(TodoApp(controller));
    await tester.pumpAndSettle();

    final chat = find.byType(AiPage);
    final list = find.descendant(of: chat, matching: find.byType(ListView));
    final footer = find.text('最新回复结尾', findRichText: true);

    Future<void> openChat() async {
      await tester.tap(find.text('AI'));
      await tester.pumpAndSettle();
      expect(footer, findsOneWidget);
      final viewport = tester.getRect(list);
      expect(tester.getRect(footer).bottom, lessThanOrEqualTo(viewport.bottom));
      expect(tester.getRect(footer).top, greaterThanOrEqualTo(viewport.top));
    }

    await openChat();
    await tester.drag(list, const Offset(0, 260));
    await tester.pumpAndSettle();
    final position = tester.widget<ListView>(list).controller!.position;
    expect(position.pixels, greaterThan(0));
    await tester.tap(find.text('任务'));
    await tester.pumpAndSettle();
    await openChat();
  });
}

class _ChatController extends TodoController {
  _ChatController() : super(MemoryRepository(), automatic: false);

  @override
  final TodoApi api = _ChatApi();
}

class _ChatApi extends TodoApi {
  _ChatApi() : super(user.server, user);

  static const user = Account(
    server: 'https://todo.example.com',
    user: 1,
    login: 1,
    personal: 1,
    token: 'mock',
    email: 'test@example.com',
    nickname: '测试',
  );

  @override
  Future<Fields> call(
    String route, {
    String method = 'POST',
    Fields values = const {},
    Duration timeout = const Duration(seconds: 16),
  }) async => {
    'configured': true,
    'data': values.containsKey('thread')
        ? [
            for (var i = 0; i < 30; i++)
              {'question': '历史问题 $i', 'answer': '回复 $i', 'state': 'done'},
            {
              'question': '最新问题',
              'answer': '${List.filled(60, '详细回复').join('\n\n')}\n\n最新回复结尾',
              'state': 'done',
            },
          ]
        : [
            {'thread': 'recent'},
          ],
  };
}
