import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import 'omi_video_backend.dart';
import 'omi_video_value.dart';

/// Web 端实现：浏览器原生 HTML video（video_player_web）。
/// 与 MDK 实现保持同一套接口。
class OmiVideoController extends ChangeNotifier implements OmiVideoBackend {
  OmiVideoController.network(
    Uri url, {
    Map<String, String>? headers,
    String? formatHint,
    int bufferSeconds = 5,
  }) {
    VideoFormat? fmt;
    if (formatHint == 'hls') fmt = VideoFormat.hls;
    if (formatHint == 'dash') fmt = VideoFormat.dash;
    _vc = VideoPlayerController.networkUrl(
      url,
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
      formatHint: fmt,
      httpHeaders: headers ?? const {},
    );
    _vc.addListener(_sync);
  }

  late final VideoPlayerController _vc;
  OmiVideoValue _value = const OmiVideoValue();
  bool _disposed = false;

  /// Web 端拿不到 PCM（video 元素不暴露 AnalyserNode 的跨域流），
  /// 电平恒为 -1，波形退回播放态模拟。
  OmiVideoValue get value => _value;

  @override
  String get engine => 'web';

  void _sync() {
    if (_disposed) return;
    final v = _vc.value;
    _value = OmiVideoValue(
      isInitialized: v.isInitialized,
      isPlaying: v.isPlaying,
      isBuffering: v.isBuffering,
      hasError: v.hasError,
      isCompleted: v.isCompleted,
      size: v.size,
      position: v.position,
      duration: v.duration,
      bufferedEnd: v.buffered.isEmpty ? Duration.zero : v.buffered.last.end,
      errorDescription: v.errorDescription,
    );
    notifyListeners();
  }

  Future<void> initialize() async {
    await _vc.initialize();
    _sync();
  }

  Future<void> play() async {
    await _vc.play();
    _sync();
  }

  Future<void> pause() async {
    await _vc.pause();
    _sync();
  }

  Future<void> setLooping(bool loop) => _vc.setLooping(loop);

  Future<void> seekTo(Duration position) => _vc.seekTo(position);

  Future<void> setVolume(double volume) => _vc.setVolume(volume);

  Widget build({BoxFit fit = BoxFit.contain}) => VideoPlayer(_vc);

  Size get videoSize => _value.size;

  Future<Uint8List?> snapshotPng() async => null;

  Future<bool> startRecord(String path) async => false;

  Future<void> stopRecord() async {}

  Future<void> release() async {
    if (_disposed) return;
    _disposed = true;
    _vc.removeListener(_sync);
    try {
      await _vc.dispose();
    } catch (_) {}
  }

  @override
  void dispose() {
    unawaited(release());
    super.dispose();
  }
}
