import 'dart:async';
import 'dart:io';

import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:open_filex/open_filex.dart';

import 'appearance.dart';
import 'domain.dart';
import 'media_files.dart';
import 'notes.dart';

class NoteBubble extends StatefulWidget {
  const NoteBubble({
    super.key,
    required this.entry,
    required this.media,
    required this.files,
    required this.scope,
    required this.onLongPress,
    required this.onRetry,
    this.enabled = true,
    this.inDocument = false,
  });
  final Fields entry, media;
  final MediaFiles files;
  final String scope;
  final VoidCallback onLongPress, onRetry;
  final bool enabled;
  final bool inDocument;
  @override
  State<NoteBubble> createState() => _NoteBubbleState();
}

class _NoteBubbleState extends State<NoteBubble> {
  late Future<File?> local = load();
  AudioPlayer? _player;
  AudioPlayer get player => _player ??= AudioPlayer();
  bool loading = false;

  Future<File?> load() => widget.files.find(
    text(widget.entry['client_media_id']),
    widget.media,
    widget.scope,
  );

  @override
  void didUpdateWidget(NoteBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.media['local_ready'] != widget.media['local_ready'] ||
        oldWidget.entry['client_media_id'] != widget.entry['client_media_id']) {
      local = load();
    }
  }

  @override
  void dispose() {
    if (_player != null) unawaited(_player!.dispose());
    super.dispose();
  }

  Future<void> play(File audio) async {
    if (loading) return;
    if (player.playing) {
      await player.pause();
      return;
    }
    setState(() => loading = true);
    try {
      if (player.audioSource == null) await player.setFilePath(audio.path);
      if (player.processingState == ProcessingState.completed) {
        await player.seek(Duration.zero);
      }
      unawaited(
        player.play().catchError((Object error) {
          if (mounted) message(context, '录音播放失败，请重试');
        }),
      );
    } catch (_) {
      if (mounted) message(context, '录音播放失败，请重试');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Widget waiting() => TextButton.icon(
    onPressed: widget.enabled
        ? () {
            setState(() => local = load());
            widget.onRetry();
          }
        : null,
    icon: Icon(
      widget.entry['kind'] == 'image'
          ? Icons.photo_outlined
          : widget.entry['kind'] == 'file'
          ? Icons.attach_file
          : Icons.mic_none,
    ),
    label: Text(
      widget.entry['kind'] == 'image'
          ? '图片等待同步'
          : widget.entry['kind'] == 'file'
          ? '文件等待同步'
          : '语音等待同步',
    ),
  );

  Widget content() {
    if (widget.entry['kind'] == 'text') {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          text(widget.entry['content']),
          style: const TextStyle(fontSize: 16, color: ink),
        ),
      );
    }
    return FutureBuilder<File?>(
      future: local,
      builder: (context, state) {
        final file = state.data;
        if (file == null) return waiting();
        if (widget.entry['kind'] == 'file') {
          return SizedBox(
            width: 260,
            child: ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: Text(
                text(widget.entry['media_name']).isEmpty
                    ? '文件'
                    : text(widget.entry['media_name'])
                          .split(RegExp(r'[\\/]'))
                          .last,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: !widget.enabled
                  ? null
                  : () async {
                      try {
                        final result = await OpenFilex.open(file.path);
                        if (context.mounted && result.type != ResultType.done) {
                          message(context, '未能打开文件，请安装支持此格式的应用');
                        }
                      } catch (_) {
                        if (context.mounted) message(context, '未能打开文件，请重试');
                      }
                    },
            ),
          );
        }
        if (widget.entry['kind'] == 'image') {
          return InkWell(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => Scaffold(
                  backgroundColor: Colors.black,
                  appBar: AppBar(title: const Text('图片')),
                  body: Center(
                    child: InteractiveViewer(
                      minScale: 0.5,
                      maxScale: 8,
                      child: Image.file(
                        file,
                        cacheWidth: 2048,
                        errorBuilder: (_, _, _) => const Text(
                          '系统暂不支持预览此原图格式',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.file(
                file,
                width: widget.inDocument ? double.infinity : 240,
                height: widget.inDocument ? null : 200,
                fit: BoxFit.contain,
                cacheWidth: 720,
                semanticLabel: '图片，点击查看原图',
                errorBuilder: (_, _, _) => const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('原图已在本机保存，系统暂不支持预览'),
                ),
              ),
            ),
          );
        }
        return StreamBuilder<PlayerState>(
          stream: player.playerStateStream,
          builder: (context, state) {
            final playing =
                state.data?.playing == true &&
                state.data?.processingState != ProcessingState.completed;
            final seconds = integer(widget.entry['duration_ms']) ~/ 1000;
            return SizedBox(
              width: 220,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                    leading: Icon(
                      playing ? Icons.pause : Icons.volume_up_outlined,
                    ),
                    title: Text(seconds > 0 ? '$seconds 秒' : '语音'),
                    trailing: loading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(playing ? Icons.graphic_eq : Icons.play_arrow),
                    onTap: widget.enabled && !loading ? () => play(file) : null,
                  ),
                  if (player.audioSource != null)
                    StreamBuilder<Duration>(
                      stream: player.positionStream,
                      builder: (_, position) {
                        final duration = player.duration?.inMilliseconds ?? 0;
                        return Slider(
                          value: (position.data?.inMilliseconds ?? 0)
                              .clamp(0, duration)
                              .toDouble(),
                          max: duration > 0 ? duration.toDouble() : 1,
                          onChanged: widget.enabled && duration > 0
                              ? (value) => player.seek(
                                  Duration(milliseconds: value.round()),
                                )
                              : null,
                        );
                      },
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.inDocument) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: GestureDetector(
            onLongPress: widget.enabled ? widget.onLongPress : null,
            child: content(),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              messageTime(widget.entry),
              style: const TextStyle(color: muted, fontSize: 12),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * 0.82,
              ),
              child: GestureDetector(
                onLongPress: widget.enabled ? widget.onLongPress : null,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: widget.entry['kind'] == 'image'
                        ? Colors.transparent
                        : const Color(0xffb2ed83),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: content(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
