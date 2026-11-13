import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:video_player/video_player.dart';

import 'omi_video_backend.dart';
import 'omi_video_value.dart';

/// MDK（libmdk）内核实现：fvp 把 `video_player` 的平台实现接管为 MDK。
///
/// 为什么保留这条引擎：Windows 上 mpv 的画面走 Flutter 纹理回传，老显卡
/// /Win10 1607 的驱动在纹理重建、面板叠加时容易掉帧闪黑；MDK 直接用
/// D3D11 渲染到纹理，同类机器上更稳。用户可在「设置 → 播放器 → 播放引擎」
/// 里切换，换台后生效。
///
/// 能力边界（与 mpv 引擎的差异，均在 UI 上做了降级）：
/// - 没有 `af` 滤镜链 → 均衡器预设/自定义 EQ 不生效
/// - 没有 af-metadata → 波形退回模拟动画（[audioLevel] 恒为 -1）
/// - 录制/截帧走 fvp 扩展（MDK 原生 `record` / `snapshot`，见 OMPlayer
///   同款实现），与 mpv 的 stream-record 一样可用
class OmiVideoMdkController extends ChangeNotifier
    implements OmiVideoBackend {
  OmiVideoMdkController.network(
    Uri url, {
    Map<String, String>? headers,
    String? formatHint,
    int bufferSeconds = 5,
    bool radioSpectrum = false,
    bool audioMeter = false,
  }) : _url = url {
    _register();
    _pc = VideoPlayerController.networkUrl(
      url,
      httpHeaders: headers ?? const <String, String>{},
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    _pc.addListener(_sync);
  }

  static bool _registered = false;

  /// 只在第一次用到 MDK 时注册：不切换引擎的用户完全不受影响（Windows
  /// 上也不会去加载 mdk.dll）。低延迟设为直播模式，丢帧保最新画面。
  static void _register() {
    if (_registered) return;
    _registered = true;
    try {
      fvp.registerWith(options: <String, dynamic>{
        // web 走官方实现；移动端/桌面端用 MDK
        'platforms': <String>['windows', 'linux', 'android', 'macos', 'ios'],
        'lowLatency': 2,
        'video.decoders': <String>[
          'MFT:d3d=11',
          'D3D11',
          'DXVA',
          'auto',
        ],
      });
    } catch (e) {
      debugPrint('[OmiVideo/mdk] register failed: $e');
    }
  }

  final Uri _url;
  late final VideoPlayerController _pc;

  @override
  final ValueNotifier<double> audioLevel = ValueNotifier<double>(-1);

  OmiVideoValue _value = const OmiVideoValue();
  bool _disposed = false;

  @override
  OmiVideoValue get value => _value;

  void _set(OmiVideoValue next) {
    if (_disposed) return;
    _value = next;
    notifyListeners();
  }

  void _sync() {
    if (_disposed) return;
    final v = _pc.value;
    _set(
      OmiVideoValue(
        isInitialized: v.isInitialized,
        isPlaying: v.isPlaying,
        isBuffering: v.isBuffering,
        hasError: v.hasError,
        isCompleted: v.isCompleted,
        size: v.size,
        position: v.position,
        duration: v.duration,
        bufferedEnd:
            v.buffered.isEmpty ? Duration.zero : v.buffered.last.end,
        mediaTitle: _value.mediaTitle,
        errorDescription: v.errorDescription,
      ),
    );
  }

  @override
  Future<void> initialize() async {
    await _pc.initialize();
    _sync();
  }

  @override
  Future<void> play() async {
    await _pc.play();
    _sync();
  }

  @override
  Future<void> pause() async {
    await _pc.pause();
    _sync();
  }

  @override
  Future<void> setLooping(bool loop) async {
    await _pc.setLooping(loop);
  }

  @override
  Future<void> seekTo(Duration position) async {
    await _pc.seekTo(position);
  }

  @override
  Future<void> setVolume(double volume) async {
    await _pc.setVolume(volume.clamp(0.0, 1.0));
  }

  @override
  Widget build({BoxFit fit = BoxFit.contain}) {
    // MDK 纹理不参与 Flutter 的 BoxFit，外层用 AspectRatio/FittedBox 约束
    return VideoPlayer(_pc);
  }

  Size get videoSize => _value.size;

  /// MDK 帧回读（fvp 的 snapshot 扩展）返回 RGBA 裸数据，这里再经
  /// dart:ui 编码成 PNG（与 OMPlayer 同款做法）；未初始化/无画面返回 null
  @override
  Future<Uint8List?> snapshotPng() async {
    try {
      if (!_pc.value.isInitialized) return null;
      final w = _pc.value.size.width.round();
      final h = _pc.value.size.height.round();
      if (w <= 0 || h <= 0) return null;
      final rgba = await fvp.FVPControllerExtensions(_pc)
          .snapshot(width: w, height: h);
      if (rgba == null || rgba.isEmpty) return null;
      final buf = await ui.ImmutableBuffer.fromUint8List(rgba);
      final desc = ui.ImageDescriptor.raw(
        buf,
        width: w,
        height: h,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      final codec = await desc.instantiateCodec();
      final frame = await codec.getNextFrame();
      final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      desc.dispose();
      buf.dispose();
      return png?.buffer.asUint8List();
    } catch (e) {
      debugPrint('[OmiVideo/mdk] snapshot failed: $e');
      return null;
    }
  }

  /// MDK 原生录制（fvp 的 record 扩展，转封装到本地文件，`to: null` 停止）。
  /// 与 mpv 的 stream-record 不同：mdk 会按输出后缀（.mp4）重新封装，
  /// 直播流同样可用；文件尾在停止时写入
  @override
  Future<bool> startRecord(String path) async {
    try {
      if (!_pc.value.isInitialized) return false;
      fvp.FVPControllerExtensions(_pc).record(to: path);
      return true;
    } catch (e) {
      debugPrint('[OmiVideo/mdk] record start failed: $e');
      return false;
    }
  }

  @override
  Future<void> stopRecord() async {
    try {
      fvp.FVPControllerExtensions(_pc).record(to: null);
    } catch (e) {
      debugPrint('[OmiVideo/mdk] record stop failed: $e');
    }
  }

  /// MDK 无 af 滤镜链：均衡器预设在这里不生效（UI 已提示）
  @override
  Future<void> applyAudioFilter(String? lavfi) async {}

  @override
  Future<void> release() async {
    if (_disposed) return;
    _disposed = true;
    _pc.removeListener(_sync);
    try {
      await _pc.dispose();
    } catch (e) {
      debugPrint('[OmiVideo/mdk] dispose failed: $e');
    }
  }

  @override
  void dispose() {
    unawaited(release());
    super.dispose();
  }

  @override
  String toString() => 'OmiVideoMdkController($_url)';
}
