import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 媒体捕获服务 - 桌面端录制与截图的文件存储
/// 录制/截帧由 fvp(MDK) 原生完成，这里只负责固定目录与 PNG 编码
class MediaCaptureService {
  /// 检查是否为桌面平台（Web 上 Platform 不可调用，先用 kIsWeb 短路）
  static bool get isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// 安卓也支持截图/录制（应用文档目录，无需存储权限）
  static bool get isAndroid => !kIsWeb && Platform.isAndroid;

  /// 安卓原生通道（与画中画/通知栏共用 MainActivity 上的 omi/pip 通道）
  static const MethodChannel _native = MethodChannel('omi/pip');

  /// 用户指定的保存根目录（设置里选的）。空 = 用默认位置。
  /// 截图/录制/录音全部走 [getSaveDir]，改一处即全部生效。
  static String overrideDir = '';

  /// 获取保存目录（截图/录制优先保存到 程序所在目录/screenshots、recordings）
  Future<String> getSaveDir(String subDir) async {
    // 用户指定目录优先（桌面端）。仍按子目录分开放，
    // 避免 recordings / radio_records / screenshots 混在一个文件夹里
    if (overrideDir.trim().isNotEmpty && !isAndroid) {
      try {
        final target = Directory('${overrideDir.trim()}/$subDir');
        await target.create(recursive: true);
        return target.path;
      } catch (_) {}
    }
    // 安卓：应用文档目录。与 RadioRecorder 的 radio_records 同根，
    // 避免「录音库打开一个文件夹、实际文件在另一个」。
    if (isAndroid) {
      final docs = await getApplicationDocumentsDirectory();
      final target = Directory('${docs.path}/$subDir');
      await target.create(recursive: true);
      return target.path;
    }
    // 优先：exe 所在文件夹下的子文件夹
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final target = Directory('$exeDir/$subDir');
      await target.create(recursive: true);
      return target.path;
    } catch (_) {}
    // 回退：程序目录不可写（如安装在受保护目录）时保存到用户视频目录
    final String base;
    if (Platform.isWindows) {
      base = '${Platform.environment['USERPROFILE']}\\Videos\\Omi';
    } else if (Platform.isMacOS) {
      base = '${Platform.environment['HOME']}/Movies/Omi';
    } else {
      base = '${Platform.environment['HOME']}/Videos/Omi';
    }
    final target = Directory('$base/$subDir');
    if (!await target.exists()) {
      await target.create(recursive: true);
    }
    return target.path;
  }

  /// 生成保存文件完整路径
  Future<String> buildFilePath(String subDir, String name, String ext) async {
    final dir = await getSaveDir(subDir);
    final ts = DateTime.now()
        .toString()
        .replaceAll(':', '-')
        .replaceAll(' ', '_')
        .split('.')
        .first;
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return '$dir/${safe}_$ts.$ext';
  }

  /// 保存字节到文件
  Future<String> saveBytes(String path, Uint8List bytes) async {
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  /// 安卓：把已落盘的截图/录像搬进系统相册（MediaStore）。
  ///
  /// 应用文档目录里的文件在相册/文件管理器里看不到，用户在手机上截完图
  /// 找不到东西。原生侧用 MediaStore 复制一份（Android 10+ 免存储权限），
  /// 复制成功后删掉应用私有副本，避免占两份空间。
  ///
  /// 返回相册内容 URI；非安卓、用户拒绝存储权限或失败时返回 null——
  /// 文件保持在应用目录，调用方按原路径提示。
  Future<String?> publishToGallery(String path, {required bool video}) async {
    if (!isAndroid) return null;
    final name = path.split(RegExp(r'[\\/]')).last;
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    final mime = !video
        ? 'image/png'
        : switch (ext) {
            'webm' => 'video/webm',
            'ts' => 'video/mp2t',
            'mkv' => 'video/x-matroska',
            _ => 'video/mp4',
          };
    try {
      // Android 9 及以下写公共相册要 WRITE_EXTERNAL_STORAGE：原生侧先
      // 检查，没有就弹系统授权框；Android 10+ 直接返回 true（免权限）
      final granted =
          await _native.invokeMethod<bool>('ensureGalleryPermission') ?? false;
      if (!granted) return null;
      final uri = await _native.invokeMethod<String>('saveToGallery', {
        'path': path,
        'name': name,
        'mime': mime,
      });
      if (uri == null || uri.isEmpty) return null;
      try {
        await File(path).delete();
      } catch (_) {}
      return uri;
    } catch (_) {
      return null;
    }
  }

  /// 追加字节到文件末尾（网页录制分块写入）
  Future<void> appendBytes(String path, Uint8List bytes) async {
    await File(path).writeAsBytes(bytes, mode: FileMode.append, flush: true);
  }

  /// 将 fvp snapshot 返回的 RGBA 数据编码为 PNG
  Future<Uint8List> rgbaToPng(
      Uint8List rgba, int width, int height) async {
    final buf = await ui.ImmutableBuffer.fromUint8List(rgba);
    final descriptor = ui.ImageDescriptor.raw(
      buf,
      width: width,
      height: height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    final png =
        await frame.image.toByteData(format: ui.ImageByteFormat.png);
    descriptor.dispose();
    buf.dispose();
    return png!.buffer.asUint8List();
  }
}
