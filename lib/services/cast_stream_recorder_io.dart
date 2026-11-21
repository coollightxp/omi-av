import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'cast_log.dart';
import 'media_capture_service.dart';

/// 投屏流级录制：直接下载投屏源的原始媒体字节落盘，不经过播放内核，
/// 也不录屏幕。
///
/// 为什么不走内核录制：投屏源多为 HLS 分片 + 鉴权 CDN，内核的
/// stream-record / record 是 fire-and-forget，遇到这类流不报错也不写
/// 数据（实测白录）。这里自己抓流：
/// - HLS：解析 m3u8（master 选最高码率、相对路径解析、直播列表轮询
///   追加新分片）。TS 分片落 .ts，fMP4（EXT-X-MAP）落 .mp4；
/// - 非 HLS：单开一条下载连接直接落盘，断流按 Range 续传。
///
/// 与播放内核完全解耦：录制期间看门狗重建播放器、切线路都不影响
/// 已开始的文件（只有换投屏/离开投屏/退出才收尾）。
class CastStreamRecorder {
  CastStreamRecorder._();

  static HttpClient? _client;
  static IOSink? _sink;
  static Future<void>? _loop;

  static bool get isRecording => _sink != null;

  static String? filePath;
  static String? lastPath;
  static int bytes = 0;

  static final ValueNotifier<Duration> elapsed = ValueNotifier(Duration.zero);

  /// 录制自然结束（VOD 播完/断流/失败）时回调；主动 stop 不回调。
  static void Function(String? error)? onFinished;

  static DateTime? _startedAt;
  static Timer? _tick;
  static bool _stopRequested = false;

  static const Duration _connectTimeout = Duration(seconds: 10);
  static const Duration _headerTimeout = Duration(seconds: 15);
  static const Duration _readTimeout = Duration(seconds: 30);

  /// 启动录制。成功返回 null；失败返回原因：
  /// 'platform'（非桌面）、'busy'（已在录）、'http'（拉流失败）、
  /// 'hls'（播放列表无法解析）、'encrypted'（AES-128 加密暂不支持）、
  /// 'io'（落盘失败）。
  static Future<String?> start({
    required String url,
    required String name,
    String userAgent = '',
    String referer = '',
  }) async {
    if (kIsWeb) return 'platform';
    if (isRecording) return 'busy';

    final headers = <String, String>{};
    if (userAgent.trim().isNotEmpty) headers['User-Agent'] = userAgent.trim();
    if (referer.trim().isNotEmpty) headers['Referer'] = referer.trim();

    _stopRequested = false;
    _startedAt = null;
    bytes = 0;
    elapsed.value = Duration.zero;
    lastPath = null;
    _client = HttpClient()..connectionTimeout = _connectTimeout;

    HttpClientResponse resp;
    try {
      resp = await _open(url, headers);
    } catch (e) {
      CastLog.write('cast rec open failed: $e');
      _closeClient();
      return 'http';
    }
    if (resp.statusCode >= 400) {
      CastLog.write('cast rec open status=${resp.statusCode}');
      _closeClient();
      return 'http';
    }

    final ct = (resp.headers.contentType?.mimeType ?? '').toLowerCase();
    final it = StreamIterator<List<int>>(resp);
    List<int>? first;
    try {
      if (await it.moveNext().timeout(_readTimeout)) first = it.current;
    } catch (_) {}

    final head = first == null
        ? ''
        : utf8.decode(first.take(32).toList(), allowMalformed: true);
    final isHls = _looksHls(url) ||
        ct.contains('mpegurl') ||
        head.contains('#EXTM3U');

    try {
      String? result;
      if (isHls) {
        final body = BytesBuilder(copy: false);
        if (first != null) body.add(first);
        while (await it.moveNext().timeout(_readTimeout)) {
          body.add(it.current);
        }
        final text = utf8.decode(body.takeBytes(), allowMalformed: true);
        result = await _startHls(text, url, name, headers);
      } else {
        result = await _startDirect(
            it, first, url, name, ct, headers, resp.contentLength);
      }
      // 启动失败（加密/解析失败等）时释放连接；成功则连接归录制循环使用
      if (result != null) _closeClient();
      return result;
    } catch (e) {
      CastLog.write('cast rec start exception: $e');
      await _finish('http', notify: false);
      return 'http';
    }
  }

  /// 停止录制，返回落盘文件路径（未在录返回 null）。
  static Future<String?> stop() async {
    if (_sink == null) return lastPath;
    _stopRequested = true;
    // 立刻扯断在途请求，分片下载/直播轮询能马上退出
    _closeClient();
    try {
      await _loop?.timeout(const Duration(seconds: 3));
    } catch (_) {}
    if (_sink != null) await _finish(null, notify: false);
    return lastPath;
  }

  // ==================== 初始化与收尾 ====================

  static Future<String?> _startDirect(
    StreamIterator<List<int>> it,
    List<int>? first,
    String url,
    String name,
    String contentType,
    Map<String, String> headers,
    int expectedTotal,
  ) async {
    final ext = _extFor(url, contentType);
    final path = await _pathFor(name, ext);
    try {
      final sink = File(path).openWrite();
      _sink = sink;
      filePath = path;
      _startClock();
      if (first != null) _write(first);
      CastLog.write('cast rec direct path=$path ext=$ext total=$expectedTotal');
      _loop = _directLoop(it, url, headers, expectedTotal);
      return null;
    } catch (e) {
      CastLog.write('cast rec direct open file failed: $e');
      await _finish('io', notify: false);
      return 'io';
    }
  }

  static Future<String?> _startHls(
    String text,
    String playlistUrl,
    String name,
    Map<String, String> headers,
  ) async {
    var url = playlistUrl;
    var pl = _HlsPlaylist.parse(text, url);
    var depth = 0;
    // master 列表：选最高码率，最多再下钻两层
    while (pl.isMaster && depth++ < 3) {
      final best = pl.bestVariant();
      if (best == null) return 'hls';
      final variantText = await _fetchText(best.url, headers);
      if (variantText == null) return 'http';
      url = best.url;
      pl = _HlsPlaylist.parse(variantText, url);
    }
    if (pl.isMaster) return 'hls';
    if (pl.encrypted) {
      CastLog.write('cast rec hls encrypted (AES-128) unsupported');
      return 'encrypted';
    }
    final ext = pl.mapUrl != null ? 'mp4' : 'ts';
    final path = await _pathFor(name, ext);
    // fMP4 的初始化段必须先写一次
    Uint8List? mapBytes;
    if (pl.mapUrl != null) {
      mapBytes = await _fetchBytes(_resolve(url, pl.mapUrl!), headers);
      if (mapBytes == null) return 'http';
    }
    try {
      final sink = File(path).openWrite();
      if (mapBytes != null) {
        sink.add(mapBytes);
        bytes = mapBytes.length;
      }
      _sink = sink;
      filePath = path;
      _startClock();
      CastLog.write('cast rec hls path=$path ext=$ext segs=${pl.segments.length} '
          'live=${!pl.endList} target=${pl.targetDuration}');
      _loop = _hlsLoop(pl, url, headers);
      return null;
    } catch (e) {
      CastLog.write('cast rec hls open file failed: $e');
      await _finish('io', notify: false);
      return 'io';
    }
  }

  static Future<void> _finish(String? error, {bool notify = true}) async {
    final path = filePath;
    _tick?.cancel();
    _tick = null;
    final sink = _sink;
    _sink = null;
    if (sink != null) {
      try {
        await sink.flush();
      } catch (_) {}
      try {
        await sink.close();
      } catch (_) {}
    }
    _closeClient();
    filePath = null;
    _startedAt = null;
    elapsed.value = Duration.zero;
    if (path != null) lastPath = path;
    CastLog.write('cast rec finished path=$path bytes=$bytes '
        'error=${error ?? "-"}');
    if (notify) {
      final cb = onFinished;
      onFinished = null;
      if (cb != null) cb(error);
    }
  }

  // ==================== 直连流 ====================

  static Future<void> _directLoop(
    StreamIterator<List<int>> it,
    String url,
    Map<String, String> headers,
    int expectedTotal,
  ) async {
    try {
      while (!_stopRequested) {
        try {
          while (await it.moveNext().timeout(_readTimeout)) {
            if (_stopRequested) break;
            _write(it.current);
          }
        } catch (e) {
          if (_stopRequested) break;
          CastLog.write('cast rec direct break sent=$bytes: $e');
        }
        if (_stopRequested) break;
        // 已知总长且已收满 = 正常播完（VOD），不要误报断流
        if (expectedTotal > 0 && bytes >= expectedTotal) {
          await _finish(null);
          return;
        }
        // 断流续传：最多 5 次，按 Range 从已写位置继续
        var resumed = false;
        for (var attempt = 1; attempt <= 5 && !_stopRequested; attempt++) {
          await Future<void>.delayed(Duration(seconds: attempt));
          try {
            final next = await _openRange(url, headers, bytes);
            if (next == null) continue;
            if (next.statusCode == 206) {
              it = StreamIterator<List<int>>(next);
              resumed = true;
              CastLog.write('cast rec direct resume from=$bytes');
              break;
            }
            if (next.statusCode == 416 &&
                expectedTotal > 0 &&
                bytes >= expectedTotal) {
              // 已经收满：Range 越界属正常收尾
              await _finish(null);
              return;
            }
            if (next.statusCode == 200) {
              // 服务器不支持 Range，从头返回：继续写会污染文件，直接收尾
              CastLog.write('cast rec direct no-range support, stop');
              break;
            }
          } catch (_) {}
        }
        if (!resumed) {
          if (_stopRequested) return;
          await _finish('network');
          return;
        }
      }
      if (_stopRequested) return;
      await _finish(null);
    } catch (e) {
      if (_stopRequested) return;
      CastLog.write('cast rec direct loop error: $e');
      await _finish('network');
    }
  }

  // ==================== HLS ====================

  static Future<void> _hlsLoop(
    _HlsPlaylist first,
    String url,
    Map<String, String> headers,
  ) async {
    var pl = first;
    var lastSeq = -1;
    var fetchFailures = 0;
    try {
      while (!_stopRequested) {
        for (var i = 0; i < pl.segments.length; i++) {
          if (_stopRequested) break;
          final seq = pl.mediaSequence + i;
          if (seq <= lastSeq) continue;
          if (lastSeq >= 0 && seq > lastSeq + 1) {
            CastLog.write('cast rec hls gap ${lastSeq + 1}..${seq - 1}');
          }
          final segUrl = _resolve(url, pl.segments[i]);
          var ok = false;
          for (var attempt = 0; attempt < 3 && !_stopRequested; attempt++) {
            ok = await _append(segUrl, headers);
            if (ok) break;
            await Future<void>.delayed(
                Duration(milliseconds: 400 * (attempt + 1)));
          }
          if (!ok) {
            CastLog.write('cast rec hls segment failed seq=$seq');
          }
          lastSeq = seq;
        }
        // VOD：列表已完整，下完即收尾
        if (pl.endList) {
          if (_stopRequested) return;
          await _finish(null);
          return;
        }
        // 直播：等新分片
        await Future<void>.delayed(_pollDelay(pl));
        if (_stopRequested) break;
        final text = await _fetchText(url, headers);
        if (text == null) {
          fetchFailures++;
          if (fetchFailures > 8) {
            await _finish('network');
            return;
          }
          continue;
        }
        fetchFailures = 0;
        final next = _HlsPlaylist.parse(text, url);
        if (next.isMaster) continue;
        // 直播窗口已滑过没下到的分片：接受缺口，从当前窗口开头继续
        if (lastSeq >= 0 && next.mediaSequence > lastSeq + 1) {
          lastSeq = next.mediaSequence - 1;
        }
        pl = next;
      }
      if (_stopRequested) return;
      await _finish(null);
    } catch (e) {
      if (_stopRequested) return;
      CastLog.write('cast rec hls loop error: $e');
      await _finish('network');
    }
  }

  static Duration _pollDelay(_HlsPlaylist pl) {
    final ms = (pl.targetDuration * 500).round().clamp(1000, 5000).toInt();
    return Duration(milliseconds: ms);
  }

  // ==================== 网络 ====================

  static Future<HttpClientResponse> _open(
      String url, Map<String, String> headers) async {
    final client = _client ??= HttpClient()..connectionTimeout = _connectTimeout;
    final req = await client.getUrl(Uri.parse(url));
    headers.forEach((k, v) => req.headers.set(k, v));
    return req.close().timeout(_headerTimeout);
  }

  static Future<HttpClientResponse?> _openRange(
      String url, Map<String, String> headers, int from) async {
    final client = _client;
    if (client == null) return null;
    final req = await client.getUrl(Uri.parse(url));
    headers.forEach((k, v) => req.headers.set(k, v));
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-');
    return req.close().timeout(_headerTimeout);
  }

  static Future<bool> _append(
      String url, Map<String, String> headers) async {
    try {
      final resp = await _open(url, headers);
      if (resp.statusCode >= 400) return false;
      await for (final chunk in resp.timeout(_readTimeout)) {
        if (_stopRequested) break;
        _write(chunk);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> _fetchText(
      String url, Map<String, String> headers) async {
    final b = await _fetchBytes(url, headers);
    if (b == null) return null;
    return utf8.decode(b, allowMalformed: true);
  }

  static Future<Uint8List?> _fetchBytes(
      String url, Map<String, String> headers) async {
    try {
      final resp = await _open(url, headers);
      if (resp.statusCode >= 400) return null;
      final body = BytesBuilder(copy: false);
      await for (final chunk in resp.timeout(_readTimeout)) {
        body.add(chunk);
      }
      return body.takeBytes();
    } catch (_) {
      return null;
    }
  }

  static void _closeClient() {
    try {
      _client?.close(force: true);
    } catch (_) {}
    _client = null;
  }

  // ==================== 落盘与状态 ====================

  static Future<String> _pathFor(String name, String ext) =>
      MediaCaptureService().buildFilePath('recordings', name, ext);

  static void _write(List<int> chunk) {
    final sink = _sink;
    if (sink == null || chunk.isEmpty) return;
    sink.add(chunk);
    bytes += chunk.length;
  }

  static void _startClock() {
    _startedAt = DateTime.now();
    elapsed.value = Duration.zero;
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      final s = _startedAt;
      if (s != null) elapsed.value = DateTime.now().difference(s);
    });
  }

  static bool _looksHls(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.m3u8') || lower.contains('.m3u');
  }

  static String _resolve(String base, String ref) {
    try {
      return Uri.parse(base).resolve(ref).toString();
    } catch (_) {
      return ref;
    }
  }

  static String _extFor(String url, String contentType) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    for (final e in const [
      'mp4',
      'm4v',
      'flv',
      'mkv',
      'webm',
      'ts',
      'mov',
      'm4a',
      'mp3',
      'aac',
    ]) {
      if (path.endsWith('.$e')) return e;
    }
    if (contentType.contains('mp4')) return 'mp4';
    if (contentType.contains('flv')) return 'flv';
    if (contentType.contains('webm')) return 'webm';
    if (contentType.contains('matroska')) return 'mkv';
    if (contentType.contains('mp2t')) return 'ts';
    return 'mp4';
  }
}

class _HlsVariant {
  _HlsVariant(this.url, this.bandwidth);

  final String url;
  final int bandwidth;
}

class _HlsPlaylist {
  _HlsPlaylist({
    required this.isMaster,
    required this.variants,
    required this.segments,
    required this.mediaSequence,
    required this.targetDuration,
    required this.endList,
    required this.mapUrl,
    required this.encrypted,
  });

  final bool isMaster;
  final List<_HlsVariant> variants;
  final List<String> segments;
  final int mediaSequence;
  final double targetDuration;
  final bool endList;
  final String? mapUrl;
  final bool encrypted;

  _HlsVariant? bestVariant() {
    if (variants.isEmpty) return null;
    final sorted = [...variants]
      ..sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
    return sorted.first;
  }

  static _HlsPlaylist parse(String text, String baseUrl) {
    final lines = const LineSplitter().convert(text);
    final variants = <_HlsVariant>[];
    final segments = <String>[];
    var isMaster = false;
    var mediaSequence = 0;
    var targetDuration = 4.0;
    var endList = false;
    String? mapUrl;
    var encrypted = false;
    var pendingBandwidth = -1;

    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        if (line.startsWith('#EXT-X-STREAM-INF')) {
          isMaster = true;
          pendingBandwidth = _attrInt(line, 'BANDWIDTH') ?? 0;
        } else if (line.startsWith('#EXT-X-MEDIA-SEQUENCE')) {
          mediaSequence = _valueInt(line) ?? 0;
        } else if (line.startsWith('#EXT-X-TARGETDURATION')) {
          targetDuration = _valueDouble(line) ?? targetDuration;
        } else if (line.startsWith('#EXT-X-ENDLIST')) {
          endList = true;
        } else if (line.startsWith('#EXT-X-MAP')) {
          mapUrl = _attr(line, 'URI');
        } else if (line.startsWith('#EXT-X-KEY')) {
          final method = _attr(line, 'METHOD');
          if (method != null && method.toUpperCase() != 'NONE') {
            encrypted = true;
          }
        }
        continue;
      }
      if (pendingBandwidth >= 0) {
        variants.add(
            _HlsVariant(CastStreamRecorder._resolve(baseUrl, line), pendingBandwidth));
        pendingBandwidth = -1;
      } else {
        segments.add(line);
      }
    }

    return _HlsPlaylist(
      isMaster: isMaster,
      variants: variants,
      segments: segments,
      mediaSequence: mediaSequence,
      targetDuration: targetDuration,
      endList: endList,
      mapUrl: mapUrl,
      encrypted: encrypted,
    );
  }

  static String? _attr(String line, String key) {
    final m = RegExp('${RegExp.escape(key)}\\s*=\\s*("[^"]*"|[^,]*)')
        .firstMatch(line);
    if (m == null) return null;
    var v = m.group(1)!.trim();
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
      v = v.substring(1, v.length - 1);
    }
    return v;
  }

  static int? _attrInt(String line, String key) =>
      int.tryParse(_attr(line, key) ?? '');

  static String _afterColon(String line) {
    final i = line.indexOf(':');
    return i < 0 ? '' : line.substring(i + 1).trim();
  }

  static int? _valueInt(String line) => int.tryParse(_afterColon(line));

  static double? _valueDouble(String line) =>
      double.tryParse(_afterColon(line).split(',').first.trim());
}
