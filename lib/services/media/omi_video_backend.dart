import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'omi_video_value.dart';

/// 播放内核统一接口（门面）。
///
/// 上层（PlayerController / 播放页）只依赖这个类型：
///
/// | 引擎 | 实现类 | 用途 |
/// |---|---|---|
/// | mdk | `OmiVideoMdkController`（omi_video_mdk.dart） | 桌面/安卓全部播放（视频、投屏、电台） |
/// | web | `OmiVideoController`（omi_video_web.dart） | 浏览器 HTML video |
///
abstract class OmiVideoBackend extends ChangeNotifier {
  OmiVideoValue get value;

  /// 引擎标识：`mdk` / `web`（日志与诊断用）
  String get engine;

  Future<void> initialize();
  Future<void> play();
  Future<void> pause();
  Future<void> setLooping(bool loop);
  Future<void> seekTo(Duration position);
  Future<void> setVolume(double volume);
  Widget build({BoxFit fit = BoxFit.contain});
  Future<Uint8List?> snapshotPng();
  Future<bool> startRecord(String path);
  Future<void> stopRecord();

  /// 异步释放 native 资源（幂等，可重复调用）
  Future<void> release();
}
