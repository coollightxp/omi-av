import 'dart:typed_data';

/// Web/无文件系统平台的空实现（截图/录制入口仅桌面端与安卓开放）
class MediaCaptureService {
  static bool get isDesktop => false;
  static bool get isAndroid => false;

  /// 用户指定的保存根目录（Web 端无文件系统，恒为空）
  static String overrideDir = '';

  Future<String> getSaveDir(String subDir) async => '';

  Future<String> buildFilePath(String subDir, String name, String ext) async =>
      '';

  Future<String> saveBytes(String path, Uint8List bytes) async => path;

  Future<void> appendBytes(String path, Uint8List bytes) async {}

  /// Web/无文件系统：没有系统相册，直接返回 null
  Future<String?> publishToGallery(String path, {required bool video}) async =>
      null;

  Future<Uint8List> rgbaToPng(
      Uint8List rgba, int width, int height) async {
    throw UnsupportedError('截图仅支持桌面端');
  }
}
