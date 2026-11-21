import 'package:flutter/services.dart';

/// Windows 系统级录制（omi_screen_recorder 插件）：
/// Graphics Capture 取播放器窗口画面 + WASAPI 进程回环取本进程声音 +
/// Media Foundation 编码 H.264+AAC 落盘 mp4。
///
/// 与播放内核（mpv/mdk）完全无关——内核转封装出不去的流（投屏 HLS、
/// 视频号等）照样能录，因为录的就是屏幕上正在放的画面。
class ScreenRecorder {
  static const MethodChannel _ch = MethodChannel('omi_screen_recorder');

  /// Win10 2004+ 才可用；其他平台 / 插件未注册一律 false
  static Future<bool> isSupported() async {
    try {
      return await _ch.invokeMethod<bool>('isSupported') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 启动录制。成功返回 null；失败返回错误描述（调用方可回退内核录制）。
  static Future<String?> start(String path,
      {int fps = 30, int bitrateMbps = 8}) async {
    try {
      final r = await _ch.invokeMethod<Map<dynamic, dynamic>>('start',
          <String, dynamic>{
        'path': path,
        'fps': fps,
        'bitrateMbps': bitrateMbps,
      });
      if (r?['ok'] == true) return null;
      final err = r?['error'];
      if (err is String && err.isNotEmpty) return err;
      return '启动失败';
    } on PlatformException catch (e) {
      return e.message ?? 'PlatformException';
    } on MissingPluginException {
      return '插件未注册';
    }
  }

  /// 停止并完成落盘（Finalize），返回本次录制毫秒数。
  static Future<int> stop() async {
    try {
      final r = await _ch.invokeMethod<Map<dynamic, dynamic>>('stop');
      final v = r?['durationMs'];
      return v is int ? v : 0;
    } catch (_) {
      return 0;
    }
  }
}
