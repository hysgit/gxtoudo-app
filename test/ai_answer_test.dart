import 'dart:convert';

import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gxtodo/ai_page.dart';
import 'package:material_ui/material_ui.dart';

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
}
