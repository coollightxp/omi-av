import 'package:flutter/foundation.dart';

/// Web 端空实现：投屏流级录制仅在桌面端提供。
class CastStreamRecorder {
  CastStreamRecorder._();

  static bool get isRecording => false;

  static String? filePath;
  static String? lastPath;
  static int bytes = 0;

  static final ValueNotifier<Duration> elapsed = ValueNotifier(Duration.zero);

  /// 录制自然结束（VOD 播完/断流/失败）时回调；主动 stop 不回调。
  static void Function(String? error)? onFinished;

  static Future<String?> start({
    required String url,
    required String name,
    String userAgent = '',
    String referer = '',
    double durationSeconds = 0,
    String subDir = 'recordings',
  }) async {
    return 'platform';
  }

  static Future<String?> stop() async => null;
}
