import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:gxtodo/appearance.dart';
import 'package:gxtodo/controller.dart';
import 'package:gxtodo/domain.dart';
import 'package:gxtodo/home.dart';
import 'package:gxtodo/media_files.dart';
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
      expect(noteMessages(data, note).single.data['kind'], kind);
      expect(data.media.length, 1);
      expect(find.text('保存'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('独立标题显示在列表，聊天正文分条展示，保存只写本机并能重启读取', (tester) async {
    final store = MemoryRepository();
    final controller = TodoController(store);
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(TodoApp(controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('便签'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建便签'));
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
