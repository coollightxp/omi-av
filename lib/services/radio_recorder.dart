import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'media_capture_service.dart';

/// 电台录音（方案 12.3 第一档）：边听边录。
///
/// 流内直接抓取、不转码：对正在播的直连 http(s) 音频流**单开一条下载
/// 连接**，原始字节落盘（mp3/aac/ogg 所录即所得，不经过播放内核，不占
/// 解码资源）。HLS(.m3u8)/DASH 需解封装合成，不支持时明确返回原因。
///
/// 带宽代价：录音期间多一路相同码率的下载（电台 32-128kbps，可忽略）。
class RadioRecorder {
  RadioRecorder._();

  static HttpClient? _client;
  static HttpClientRequest? _req;
  static StreamSubscription<List<int>>? _sub;
  static IOSink? _sink;

  static bool get isRecording => _sink != null;

  static String? filePath;
  static String title = '';
  static int bytes = 0;

  /// 录制时长（每秒走字，播放页徽标直接订阅）
  static final ValueNotifier<Duration> elapsed = ValueNotifier(Duration.zero);

  static DateTime? _startedAt;
  static Timer? _tick;

  /// 启动录音。成功返回 null；失败返回原因：
  /// 'busy'（已在录）、'hls'（HLS 直播流暂不支持）、'http'（流请求失败）。
  static Future<String?> start({
    required String url,
    required String name,
    String userAgent = '',
    String referer = '',
  }) async {
    if (kIsWeb) return 'platform';
    if (isRecording) return 'busy';
    final lower = url.toLowerCase().split('?').first;
    if (lower.endsWith('.m3u8') ||
        lower.endsWith('.mpd') ||
        lower.endsWith('.m3u')) {
      return 'hls';
    }
    var ext = 'mp3';
    for (final e in const ['aac', 'm4a', 'ogg', 'opus', 'flac', 'wav']) {
      if (lower.endsWith('.$e')) {
        ext = e;
        break;
      }
    }
    final path = await buildFilePath(name, ext);
    try {
      final client = HttpClient();
      client.userAgent =
          userAgent.isNotEmpty ? userAgent : 'okhttp/3.15';
      final req = await client.getUrl(Uri.parse(url));
      if (referer.isNotEmpty) req.headers.set(HttpHeaders.refererHeader, referer);
      final resp = await req.close();
      if (resp.statusCode >= 400) {
        client.close(force: true);
        return 'http';
      }
      final sink = File(path).openWrite();
      filePath = path;
      title = name;
      bytes = 0;
      _startedAt = DateTime.now();
      elapsed.value = Duration.zero;
      _sink = sink;
      _req = req;
      _client = client;
      _sub = resp.listen(
        (chunk) {
          bytes += chunk.length;
          sink.add(chunk);
        },
        onError: (_) => unawaited(stop()),
        onDone: () => unawaited(stop()),
        cancelOnError: true,
      );
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        final s = _startedAt;
        if (s != null) elapsed.value = DateTime.now().difference(s);
      });
      return null;
    } catch (_) {
      filePath = null;
      try {
        _client?.close(force: true);
      } catch (_) {}
      _client = null;
      return 'http';
    }
  }

  /// 停止录音，返回落盘文件路径（未在录返回 null）
  static Future<String?> stop() async {
    if (_sink == null) return null;
    final path = filePath;
    _tick?.cancel();
    _tick = null;
    try {
      await _sub?.cancel();
    } catch (_) {}
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    try {
      _req?.abort();
    } catch (_) {}
    try {
      _client?.close(force: true);
    } catch (_) {}
    _sub = null;
    _sink = null;
    _req = null;
    _client = null;
    filePath = null;
    _startedAt = null;
    elapsed.value = Duration.zero;
    return path;
  }

  // ==================== 录音库管理 ====================

  /// 录音保存目录：Windows 优先 exe 旁（与截图/录屏同族），
  /// 安卓用应用文档目录
  static Future<String> saveDir() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/radio_records');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir.path;
    }
    return MediaCaptureService().getSaveDir('radio_records');
  }

  /// 全部录音，按时间新→旧
  static Future<List<File>> list() async {
    try {
      final dir = Directory(await saveDir());
      if (!await dir.exists()) return const [];
      final files = await dir
          .list()
          .where((e) => e is File)
          .map((e) => e as File)
          .toList();
      // 取修改时间排序（新 → 旧）
      final withTs = <MapEntry<File, DateTime>>[];
      for (final f in files) {
        try {
          withTs.add(MapEntry(f, (await f.stat()).modified));
        } catch (_) {}
      }
      withTs.sort((a, b) => b.value.compareTo(a.value));
      return withTs.map((e) => e.key).toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> delete(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 桌面端打开录音文件夹
  static Future<void> openFolder() async {
    if (kIsWeb) return;
    try {
      final dir = await saveDir();
      if (Platform.isWindows) {
        await Process.run('explorer.exe', [dir]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [dir]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [dir]);
      }
    } catch (_) {}
  }

  /// 文件名：台名_年月日_时分秒.ext（去非法字符）
  static Future<String> buildFilePath(String name, String ext) async {
    final dir = await saveDir();
    final ts = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final safe =
        name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return '$dir/${safe}_${ts.year}${two(ts.month)}${two(ts.day)}_'
        '${two(ts.hour)}${two(ts.minute)}${two(ts.second)}.$ext';
  }

  /// 文件大小可读格式
  static String humanSize(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
