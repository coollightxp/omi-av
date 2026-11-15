import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'omi_video_value.dart';

/// 播放内核统一接口（双引擎的门面）。
///
/// 上层（PlayerController / 播放页）只依赖这个类型，不关心底层是
/// libmpv(media_kit) 还是 MDK(fvp + video_player)：
///
/// | 引擎 | 实现类 | 适用 |
/// |---|---|---|
/// | mpv | `OmiVideoController`（omi_video_io.dart） | 默认，功能最全（音量/滤镜/录制/截帧/电平） |
/// | mdk | `OmiVideoMdkController`（omi_video_mdk.dart） | 老显卡/老系统上 D3D11 纹理更稳，不闪黑 |
/// | web | `OmiVideoController`（omi_video_web.dart） | 浏览器 HTML video |
///
/// 能力差异：MDK 引擎不支持 mpv 的 `af` 滤镜链，因此均衡器/真电平波形
/// 在 MDK 下不生效（波形自动退回模拟动画），其余播放控制完全一致。
abstract class OmiVideoBackend extends ChangeNotifier {
  OmiVideoValue get value;

  /// 实时音频电平 0~1（-1 = 未知）。仅 mpv 引擎提供；MDK 恒为 -1，
  /// 波形组件据此退回模拟动画
  ValueNotifier<double> get audioLevel;

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

  /// mpv 专属；MDK 下为空实现
  Future<void> applyAudioFilter(String? lavfi);

  /// 关掉/恢复视频输出（mpv `vid=no`/`auto`）。
  /// 后台切台（通知栏上一台/下一台）时安卓侧没有 Surface，新播放器
  /// 等纹理会卡住起播——音频先走 vid=no，回前台再恢复。
  /// MDK/Web 下为空实现。
  Future<void> setVideoOutputDisabled(bool disabled);

  /// 原地换源：不重建内核，直接让现有播放器换一路流。
  ///
  /// 只给「安卓后台电台切台」用：后台没有 Surface，新建内核的 texture
  /// 管线拿不到画布，open 会一直停在等纹理上（实测：通知栏点下一台，
  /// 声音不响，回到界面才跳台）。原地 open 沿用已有的音频输出，
  /// 后台照样出声。
  ///
  /// 默认实现抛 [UnsupportedError]（MDK/Web 不支持），调用方捕获后
  /// 回退到重建内核的老路径。
  Future<void> openInPlace(Uri url, {Map<String, String>? headers}) async {
    throw UnsupportedError('当前内核不支持原地换源');
  }

  /// 异步释放 native 资源（幂等，可重复调用）
  Future<void> release();
}
