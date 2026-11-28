import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:gxtodo/appearance.dart';
import 'package:gxtodo/controller.dart';
import 'package:gxtodo/domain.dart';
import 'package:gxtodo/home.dart';
import 'package:gxtodo/media_files.dart';
import 'package:gxtodo/note_bubble.dart';
import 'package:gxtodo/note_editor.dart';
import 'package:gxtodo/notes.dart';
import 'package:material_ui/material_ui.dart';

import 'memory_repository.dart';

void main() {
  for (final kind in ['image', 'audio']) {
    testWidgets('$kind 加入后立即落盘，不需要保存按钮且不发送尚未提交的文字', (tester) async {
      const recorderChannel = MethodChannel('com.llfbandit.record/messages');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        recorderChannel,
        (_) async => null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          recorderChannel,
          null,
        ),
      );
      late Directory folder;
      late File source;
      await tester.runAsync(() async {
        folder = await Directory.systemTemp.createTemp('todo-auto-media-');
        source = File('${folder.path}/source');
        await source.writeAsBytes([1, 2, 3, 4]);
      });
      addTearDown(() => tester.runAsync(() => folder.delete(recursive: true)));
      final store = MemoryRepository();
      final controller = TodoController(store);
      addTearDown(controller.dispose);
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: NoteEditor(
            controller,
            -1,
            files: MediaFiles(root: Directory('${folder.path}/files')),
          ),
        ),
      );
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.hintText == '输入内容',
        ),
        '未发送草稿',
      );
      final dynamic editor = tester.state(find.byType(NoteEditor));
      editor.busy = true; // 相册选择和结束录音期间也必须能写入本机。
      var completed = false;
      final Future<void> addition =
          editor.addFile(source.path, kind, '来源文件') as Future<void>;
      addition.then((_) => completed = true);
      for (var attempt = 0; !completed && attempt < 100; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.idle();
      }
      expect(completed, true);
      await addition;
      await tester.runAsync(() => source.delete());
      final data = await store.read(Identity.guest.scope);
      final note = data.list(-1, Tables.note).single;
      expect(noteSection(note), NoteSection.quick);
      expect(noteMessages(data, note).single.data['kind'], kind);
      expect(data.media.length, 1);
      expect(find.text('保存'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('速记保留旧便签，精髓和内核按创建年月分组并独立新增', (tester) async {
    final store = MemoryRepository();
    final controller = TodoController(store);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.mutate((data, who) {
      for (final (uid, title, section, created) in [
        ('quick', '旧便签', NoteSection.quick, DateTime(2025, 11, 7, 12)),
        ('essence-new', '本年记录', NoteSection.essence, DateTime(2025, 11, 5, 12)),
        ('essence-old', '往年记录', NoteSection.essence, DateTime(2024, 3, 6, 12)),
        ('core', '内核记录', NoteSection.core, DateTime(2025, 2, 1, 12)),
      ]) {
        data.save(who, -1, Tables.note, uid, {
          'name': title,
          'title': title,
          'created_at': created.toUtc().toString().split('.').first,
          if (section != NoteSection.quick) noteSectionField: section.name,
        });
      }
    });

    await tester.pumpWidget(TodoApp(controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('便签'));
    await tester.pumpAndSettle();
    expect(find.text('旧便签'), findsOneWidget);
    for (final label in ['搜索便签文字', '年份', '按日期', '全部']) {
      expect(find.text(label), findsNothing);
    }

    await tester.tap(find.text('精髓'));
    await tester.pumpAndSettle();
    expect(find.text('旧便签'), findsNothing);
    expect(find.text('2025 年'), findsOneWidget);
    expect(find.text('11 月'), findsOneWidget);
    expect(find.text('2025-11-05 本年记录'), findsOneWidget);
    expect(find.text('2024-03-06 往年记录'), findsNothing);
    await tester.tap(find.text('2024 年'));
    await tester.pumpAndSettle();
    expect(find.text('3 月'), findsOneWidget);
    expect(find.text('2024-03-06 往年记录'), findsOneWidget);

    await tester.tap(find.text('内核'));
    await tester.pumpAndSettle();
    expect(find.text('2025-11-05 本年记录'), findsNothing);
    expect(find.text('2025-02-01 内核记录'), findsOneWidget);
    await tester.tap(find.byTooltip('新建记事本'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '笔记题目'), '新内核');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    final input = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.hintText == '内容',
    );
    expect(find.text('发送'), findsNothing);
    await tester.enterText(input, '第一段笔记\n\n第二段笔记');
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    final saved = await store.read(Identity.guest.scope);
    final note = saved
        .list(-1, Tables.note)
        .firstWhere((row) => row.name == '新内核');
    expect(noteSection(note), NoteSection.core);
    expect(noteCreated(note), isNotNull);
    expect(find.text(notebookTitle(note)), findsOneWidget);
    expect(noteMessages(saved, note).map((row) => row.data['content']), [
      '第一段笔记\n\n第二段笔记',
    ]);
  });

  testWidgets('手机日记手建三层目录并保存自定义标题，信息单独显示', (tester) async {
    final store = MemoryRepository();
    final controller = TodoController(store);
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(TodoApp(controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('便签'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日记'));
    await tester.pumpAndSettle();
    for (final name in ['生活', '旅行', '随笔']) {
      await tester.tap(find.text('新建目录'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '目录名称'), name);
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();
    }
    expect(find.text('生活 / 旅行 / 随笔'), findsOneWidget);
    final add = tester.widget<TextButton>(
      find.ancestor(of: find.text('新建目录'), matching: find.byType(TextButton)),
    );
    expect(add.onPressed, isNull);
    await tester.tap(find.byTooltip('新建记事本'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '笔记题目'), '自填标题');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '内容'), '旅途的正文');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('自填标题'), findsOneWidget);
    final data = await store.read(Identity.guest.scope);
    final entry = data
        .list(-1, Tables.note)
        .firstWhere((row) => row.name == '自填标题');
    expect(noteSection(entry), NoteSection.diary);
    expect(
      noteFolderParent(entry),
      notebookFolders(data, -1, NoteSection.diary).last.uid,
    );
    expect(noteMessages(data, entry).single.data['content'], '旅途的正文');
    await tester.tap(find.text('信息'));
    await tester.pumpAndSettle();
    expect(find.text('自填标题'), findsNothing);
    expect(find.text('根目录'), findsOneWidget);
  });

  testWidgets('精髓旧正文原位可编辑，插入图片后保持正文顺序', (tester) async {
    const recorder = MethodChannel('com.llfbandit.record/messages');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      recorder,
      (_) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        recorder,
        null,
      ),
    );
    late Directory folder;
    late File source;
    await tester.runAsync(() async {
      folder = await Directory.systemTemp.createTemp('todo-notebook-image-');
      source = File('${folder.path}/source.png');
      await source.writeAsBytes(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jfusAAAAASUVORK5CYII=',
        ),
      );
    });
    addTearDown(() => tester.runAsync(() => folder.delete(recursive: true)));
    final store = MemoryRepository();
    final controller = TodoController(store, automatic: false);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.mutate(
      (data, who) => saveConversation(
        data,
        who,
        -1,
        '49-doc',
        '读书笔记',
        [
          {
            'uid': '50-first',
            'kind': 'text',
            'content': '第一段原文',
            'entry_at': 1000,
          },
          {
            'uid': '50-second',
            'kind': 'text',
            'content': '第二段原文',
            'entry_at': 1000,
          },
        ],
        {},
        section: NoteSection.essence,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: todoTheme(),
        home: NoteEditor(
          controller,
          -1,
          note: controller.data.get(-1, Tables.note, '49-doc'),
          files: MediaFiles(root: Directory('${folder.path}/media')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('插入图片'), findsOneWidget);
    expect(find.text('发送'), findsNothing);
    expect(find.byType(NoteBubble), findsNothing);
    final first = find.byKey(const ValueKey('50-first'));
    expect(tester.widget<TextField>(first).controller!.text, '第一段原文');
    await tester.enterText(first, '修改后的第一段');
    await tester.pump();
    final dynamic editor = tester.state(find.byType(NoteEditor));
    var completed = false;
    final addition =
        editor.addFile(source.path, 'image', '原图.png') as Future<void>;
    addition.then((_) => completed = true);
    for (var attempt = 0; !completed && attempt < 100; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.idle();
    }
    expect(completed, isTrue);
    await addition;
    await tester.pumpAndSettle();

    final saved = await store.read(Identity.guest.scope);
    final entries = noteMessages(saved, saved.get(-1, Tables.note, '49-doc')!);
    expect(entries.map((row) => row.data['kind']), ['text', 'image', 'text']);
    expect(entries.first.data['content'], '修改后的第一段');
    expect(entries.last.data['content'], '第二段原文');
    expect(saved.media, hasLength(1));
    expect(
      tester.widget<NoteBubble>(find.byType(NoteBubble)).inDocument,
      isTrue,
    );
    expect(find.text(messageTime(entries[1].data)), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('独立标题显示在列表，聊天正文分条展示，保存只写本机并能重启读取', (tester) async {
    final store = MemoryRepository();
    final controller = TodoController(store);
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(TodoApp(controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('便签'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('新建便签'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '便签标题'), '日常记录');
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.hintText == '输入内容',
      ),
      '第一条正文',
    );
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    expect(find.text('第一条正文'), findsOneWidget);
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.hintText == '输入内容',
      ),
      '第二条正文',
    );
    expect(find.text('保存'), findsNothing);
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('日常记录'), findsOneWidget);
    expect(find.text('第一条正文'), findsNothing);
    final reopened = TodoController(store);
    addTearDown(reopened.dispose);
    await reopened.initialize();
    final note = reopened.data.list(-1, Tables.note).single;
    expect(noteTitle(note), '日常记录');
    expect(
      noteMessages(reopened.data, note).map((row) => row.data['content']),
      ['第一条正文', '第二条正文'],
    );
    expect(
      noteMessages(
        reopened.data,
        note,
      ).every((row) => integer(row.data['entry_at']) > 0),
      true,
    );
  });

  for (final size in [const Size(375, 812), const Size(812, 375)]) {
    testWidgets('聊天图片不显示文件名或路径，适应 $size 和大字体', (tester) async {
      late Directory folder;
      late MediaFiles files;
      late Fields media;
      await tester.runAsync(() async {
        folder = await Directory.systemTemp.createTemp('todo-chat-layout-');
        files = MediaFiles(root: folder);
        final source = File('${folder.path}/source.png');
        await source.writeAsBytes(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jfusAAAAASUVORK5CYII=',
          ),
        );
        media = await files.importFile(source, 'image');
      });
      addTearDown(() => tester.runAsync(() => folder.delete(recursive: true)));
      final controller = TodoController(MemoryRepository());
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.mutate(
        (data, who) => saveConversation(
          data,
          who,
          -1,
          '49-test',
          '聊天标题',
          [
            {
              'uid': '50-a',
              'kind': 'text',
              'content': '文字内容',
              'entry_at': 1000,
            },
            {
              ...media,
              'uid': '50-b',
              'kind': 'image',
              'entry_at': 62000,
              'media_name': '/private/cache/image_picker-secret-path.png',
            },
          ],
          {text(media['client_media_id']): media},
        ),
      );
      final note = controller.data.get(-1, Tables.note, '49-test')!;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: todoTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: NoteEditor(controller, -1, note: note, files: files),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('image_picker'), findsNothing);
      expect(find.textContaining('/private'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
