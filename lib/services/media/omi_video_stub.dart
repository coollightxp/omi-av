import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'omi_video_backend.dart';
import 'omi_video_value.dart';

/// 既非 io 也非 web 的目标（理论上不存在）：编译占位。
class OmiVideoController extends ChangeNotifier
    implements OmiVideoBackend {
  OmiVideoController.network(
    Uri url, {
    Map<String, String>? headers,
    String? formatHint,
    int bufferSeconds = 5,
    bool radioSpectrum = false,
    bool audioMeter = false,
  });

  final ValueNotifier<double> audioLevel = ValueNotifier<double>(-1);

  OmiVideoValue get value => const OmiVideoValue();

  Future<void> initialize() async =>
      throw UnsupportedError('当前平台无视频内核实现');

  Future<void> play() async {}
  Future<void> pause() async {}
  Future<void> setLooping(bool loop) async {}
  Future<void> seekTo(Duration position) async {}
  Future<void> setVolume(double volume) async {}

  Widget build({BoxFit fit = BoxFit.contain}) => const SizedBox.shrink();

  Future<Uint8List?> snapshotPng() async => null;
  Future<bool> startRecord(String path) async => false;

  /// 音频滤镜（Web 无 mpv）：no-op
  Future<void> applyAudioFilter(String? lavfi) async {}

  @override
  Future<void> setVideoOutputDisabled(bool disabled) async {}
  Future<void> stopRecord() async {}

  Future<void> release() async {}

  Size get videoSize => Size.zero;
}
