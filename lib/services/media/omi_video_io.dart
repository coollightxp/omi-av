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
    bool radioSpectrum = false,
  }) : _url = url,
       _headers = headers,
       _radioSpectrum = radioSpectrum {
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
    _observeMediaTitle();
  }

  final Uri _url;
  final Map<String, String>? _headers;
  final bool _radioSpectrum;
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

  /// 电台流的曲目元数据：libmpv 把 ICY `StreamTitle` 映射到 `media-title`，
  /// 属性变化事件比轮询省事也更及时。Web 端没有 mpv，不参与。
  void _observeMediaTitle() {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    unawaited(() async {
      try {
        await platform.observeProperty('media-title', (value) async {
          final t = value.trim();
          if (t.isEmpty || t == _value.mediaTitle) return;
          _set(_value.copyWith(mediaTitle: t));
        });
      } catch (e) {
        // 某些内核/资源不允许观测：静默降级，标题回落到台名
        debugPrint('[OmiVideo] observe media-title failed: $e');
      }
    }());
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
    if (_radioSpectrum) await _applySpectrumFilter();
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
    if (_spectrumApplied) {
      // 6 秒内报错 = 滤镜链建不起来（mpv 未编 showwaves / 流不支持），
      // 摘掉重开；正常出声的流不会走到这里
      _spectrumGuard?.cancel();
      _spectrumGuard = Timer(const Duration(seconds: 6), () {
        if (_disposed) return;
        if (_value.hasError) unawaited(_dropSpectrumFilter());
      });
    }
  }

  /// 电台专用：用 libmpv 的 lavfi-complex 把音频喂给 ffmpeg 的
  /// showwaves，让 mpv 输出"真实波形"视频帧，Flutter 侧当纹理贴出来。
  /// 这样波形是跟着真实 PCM 起伏的，不需要自己抓音频做 FFT。
  ///
  /// 滤镜链：aid1 一分为二，一路照常出声 [ao]，一路画成波形 [vo]。
  /// 如果当前 mpv 构建没编进 showwaves，open 后会报错，[initialize]
  /// 里的兜底定时器会摘掉滤镜重开，退回缓动波形。
  Future<void> _applySpectrumFilter() async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty(
        'lavfi-complex',
        '[aid1]asplit[ao][sp];'
            '[sp]showwaves=s=480x96:mode=cline:rate=25:colors=0xFFFFFF[vo]',
      );
      _spectrumApplied = true;
    } catch (e) {
      debugPrint('[OmiVideo] lavfi-complex failed: $e');
    }
  }

  bool _spectrumApplied = false;
  Timer? _spectrumGuard;

  /// 频谱滤镜起不来时的自愈：摘掉滤镜重开同一路流
  Future<void> _dropSpectrumFilter() async {
    if (!_spectrumApplied || _disposed) return;
    _spectrumApplied = false;
    try {
      final platform = _player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('lavfi-complex', '');
      }
      await _player.open(
        Media(_url.toString(), httpHeaders: _headers),
        play: _value.isPlaying,
      );
    } catch (e) {
      debugPrint('[OmiVideo] drop spectrum failed: $e');
    }
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

  /// 应用音频滤镜（声音实验室，方案 12.3 第二档）。
  /// [lavfi] 为 lavfi 滤镜串（不含外层 lavfi=[] 包装）；null/空清除。
  /// 换台会重建控制器，调用方需在新建控制器后重新应用。
  Future<void> applyAudioFilter(String? lavfi) async {
    try {
      final platform = _player.platform;
      if (platform is NativePlayer) {
        if (lavfi == null || lavfi.trim().isEmpty) {
          await platform.command(['af', 'clear']);
        } else {
          await platform.command(['af', 'set', 'lavfi=[${lavfi.trim()}]']);
        }
      }
    } catch (_) {}
  }

  /// 异步释放 native 资源（可 await / 可加超时）。
  /// 不覆盖 ChangeNotifier.dispose（其返回 void），由上层显式调用。
  Future<void> release() async {
    if (_disposed) return;
    _disposed = true;
    _spectrumGuard?.cancel();
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
