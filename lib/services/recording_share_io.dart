/// 录音分享实现（IO 平台）：share_plus 接系统分享，失败回退复制路径。
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

Future<void> shareRecording(String path, String name) async {
  try {
    await SharePlus.instance.share(
      ShareParams(files: [XFile(path)], text: name),
    );
  } catch (_) {
    // 系统分享不可用（老系统/无分享目标）：退而求其次复制路径，
    // 用户可自行到文件管理器取文件
    await Clipboard.setData(ClipboardData(text: path));
  }
}
