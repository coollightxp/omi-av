/// 非 IO 环境（Web）占位：系统级录制仅 Windows 桌面端
class ScreenRecorder {
  static Future<bool> isSupported() async => false;

  static Future<String?> diagnose() async => null;

  static Future<String?> start(String path,
      {int fps = 30, int bitrateMbps = 8}) async {
    return 'platform';
  }

  static Future<ScreenRecordStop> stop() async =>
      const ScreenRecordStop(0, 0, 0);
}

class ScreenRecordStop {
  final int durationMs;
  final int frames;
  final int encoded;
  const ScreenRecordStop(this.durationMs, this.frames, this.encoded);
}
