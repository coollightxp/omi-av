import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'omi_video_value.dart';

/// media_kit(libmpv) 内核实现：Android / Windows / Linux。
///
/// 设计要点：
/// - 与旧 video_player/fvp 栈保持同构 API，业务层零改动迁移；
/// - libmpv 自带 HLS/DASH/RTSP 与断点续传，不再需要 fvp 注册与 MDK SDK；
/// - 事件全部转成 [OmiVideoValue]，上层只依赖值对象。
class OmiVideoController extends ChangeNotifier {
  OmiVideoController.network(
    Uri url, {
    Map<String, String>? headers,
    String? formatHint,
    int bufferSeconds = 5,
  }) : _url = url,
       _headers = headers {
    MediaKit.ensureInitialized();
    final bytes = (bufferSeconds.clamp(3, 120)) * 1024 * 1024;
    _player = Player(
      configuration: PlayerConfiguration(
        title: 'Omi',
        bufferSize: bytes,
        logLevel: MPVLogLevel.error,
      ),
    );
    _video = VideoController(_player);
    _bindStreams();
  }

  final Uri _url;
  final Map<String, String>? _headers;
  late final Player _player;
  late final VideoController _video;
  final List<StreamSubscription<dynamic>> _subs = [];

  OmiVideoValue _value = const OmiVideoValue();
  bool _disposed = false;

  OmiVideoValue get value => _value;

  void _set(OmiVideoValue next) {
    if (_disposed) return;
    _value = next;
    notifyListeners();
  }

  void _bindStreams() {
    _subs.addAll([
      _player.stream.playing.listen(
        (v) => _set(_value.copyWith(isPlaying: v)),
      ),
      _player.stream.buffering.listen(
        (v) => _set(_value.copyWith(isBuffering: v)),
      ),
      _player.stream.completed.listen(
        (v) => _set(_value.copyWith(isCompleted: v)),
      ),
      _player.stream.error.listen(
        (e) => _set(
          _value.copyWith(hasError: true, errorDescription: e.toString()),
        ),
      ),
      _player.stream.width.listen(
        (w) => _set(
          _value.copyWith(
            size: Size(
              (w ?? _value.size.width).toDouble(),
              _value.size.height,
            ),
          ),
        ),
      ),
      _player.stream.height.listen(
        (h) => _set(
          _value.copyWith(
            size: Size(
              _value.size.width,
              (h ?? _value.size.height).toDouble(),
            ),
          ),
        ),
      ),
      _player.stream.position.listen(
        (p) => _set(_value.copyWith(position: p)),
      ),
      _player.stream.duration.listen(
        (d) => _set(_value.copyWith(duration: d)),
      ),
      _player.stream.buffer.listen(
        (b) => _set(_value.copyWith(bufferedEnd: b)),
      ),
    ]);
  }

  Future<void> initialize() async {
    await _player.open(
      Media(_url.toString(), httpHeaders: _headers),
      play: false,
    );
    // open 返回即 demuxer 就绪；画面尺寸可能稍后才上报，
    // 这里用当前已知值兜底，后续由 stream 持续修正。
    final w = _player.state.width ?? 0;
    final h = _player.state.height ?? 0;
    _set(
      _value.copyWith(
        isInitialized: true,
        size: Size(w.toDouble(), h.toDouble()),
        duration: _player.state.duration,
      ),
    );
  }

  Future<void> play() async {
    await _player.play();
    _set(_value.copyWith(isPlaying: true, hasError: false));
  }

  Future<void> pause() async {
    await _player.pause();
    _set(_value.copyWith(isPlaying: false));
  }

  Future<void> setLooping(bool loop) async {
    await _player.setPlaylistMode(loop ? PlaylistMode.loop : PlaylistMode.none);
  }

  Future<void> seekTo(Duration position) async {
    await _player.seek(position);
  }

  Future<void> setVolume(double volume) async {
    await _player.setVolume((volume.clamp(0.0, 1.0)) * 100);
  }

  Widget build({BoxFit fit = BoxFit.contain}) {
    return Video(
      controller: _video,
      controls: NoVideoControls,
      fit: fit,
    );
  }

  Size get videoSize => _value.size;

  /// 原生截帧：libmpv 直接输出 PNG 字节
  Future<Uint8List?> snapshotPng() async {
    try {
      return await _player.screenshot(format: 'image/png');
    } catch (_) {
      return null;
    }
  }

  /// 录制：libmpv 的 stream-record 直接落盘为容器文件
  Future<bool> startRecord(String path) async {
    try {
      final platform = _player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('stream-record', path);
        return true;
      }
    } catch (_) {}
    return false;
  }

  Future<void> stopRecord() async {
    try {
      final platform = _player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('stream-record', '');
      }
    } catch (_) {}
  }

  /// 异步释放 native 资源（可 await / 可加超时）。
  /// 不覆盖 ChangeNotifier.dispose（其返回 void），由上层显式调用。
  Future<void> release() async {
    if (_disposed) return;
    _disposed = true;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    try {
      await _player.dispose();
    } catch (_) {}
  }

  @override
  void dispose() {
    // 兜底路径：没人 await 的调用方也要释放 native 资源。
    // release 自身幂等，与上层显式调用不冲突
    unawaited(release());
    super.dispose();
  }
}
