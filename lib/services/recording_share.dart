import 'package:flutter/foundation.dart';

import 'recording_share_io.dart'
    if (dart.library.html) 'recording_share_stub.dart';

/// 录音文件分享（方案 12.3 收尾）：接系统分享面板。
/// 安卓弹出系统分享（微信/QQ/蓝牙/文件管理…）；
/// Windows 用系统「共享」浮窗（Win10+ 支持），失败时回退复制路径。
class RecordingShare {
  RecordingShare._();

  static Future<void> share(String path, String name) async {
    if (kIsWeb) return;
    await shareRecording(path, name);
  }
}
