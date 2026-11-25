import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:enough_convert/enough_convert.dart';
import 'package:fl_charset/fl_charset.dart';

/// ICY（Icecast/SHOUTcast）元数据读取器：自己开一条 HTTP 连接，按
/// `icy-metaint` 周期读出 `StreamTitle`，用于电台「正在播放」与通知卡片。
///
/// 为什么需要它：MDK/fvp 只交音频 PCM，不暴露 ICY 元数据；原来这个歌名
/// 是 libmpv 的 `media-title` 给的。电台切到 MDK 后由这里补齐，卡片/曲目
/// 历史/歌词锚点的数据源不变（都是同一个标题字符串）。
///
/// 注意：HLS（m3u8）没有 `icy-metaint`，这里会直接退出，不占连接。
class IcyMetadataReader {
  IcyMetadataReader({required this.onTitle});

  /// 标题变化回调（已做基本清理，未做业务过滤）
  final void Function(String title) onTitle;

  bool _running = false;

  /// 连接代际：start/stop 自增，旧循环醒来后据此自行退出
  int _gen = 0;
  HttpClient? _client;
  StreamSubscription<List<int>>? _sub;
  Completer<void>? _connDone;

  Future<void> start(Uri url, {Map<String, String>? headers}) async {
    await stop();
    _running = true;
    final gen = ++_gen;
    unawaited(_loop(gen, url, headers));
  }

  Future<void> stop() async {
    _running = false;
    _gen++;
    final done = _connDone;
    _connDone = null;
    if (done != null && !done.isCompleted) done.complete();
    final sub = _sub;
    _sub = null;
    try {
      await sub?.cancel();
    } catch (_) {}
    try {
      _client?.close(force: true);
    } catch (_) {}
    _client = null;
  }

  Future<void> _loop(int gen, Uri url, Map<String, String>? headers) async {
    var failCount = 0;
    while (_running && gen == _gen) {
      try {
        await _connectOnce(gen, url, headers);
        failCount = 0;
      } catch (_) {
        failCount++;
      }
      if (!_running || gen != _gen) return;
      // 服务器断开/连不上：退避重连（电台常挂很久，不能一断就放弃）
      final wait = failCount == 0 ? 2 : math.min(30, 5 * failCount);
      await Future<void>.delayed(Duration(seconds: wait));
    }
  }

  /// 连一次并读到流结束（或被 stop 打断）。HLS 无 icy-metaint 时直接返回。
  Future<void> _connectOnce(
      int gen, Uri url, Map<String, String>? headers) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(seconds: 30);
    _client = client;
    final req = await client.getUrl(url);
    req.headers.set('Icy-MetaData', '1');
    req.headers.set(HttpHeaders.acceptHeader, '*/*');
    headers?.forEach((k, v) => req.headers.set(k, v));
    final resp = await req.close();
    if (resp.statusCode >= 400) {
      await resp.drain<void>();
      throw HttpException('ICY status ${resp.statusCode}');
    }
    final metaint =
        int.tryParse(resp.headers.value('icy-metaint') ?? '') ?? 0;
    if (metaint <= 0) {
      // HLS / 普通 HTTP 流：没有 ICY 元数据，本台不会有歌名
      _running = false;
      client.close(force: true);
      return;
    }

    final completer = Completer<void>();
    _connDone = completer;
    // 状态机：0=跳过音频段 1=读长度字节 2=读元数据块
    var state = 0;
    var remaining = metaint;
    var metaLen = 0;
    final metaBuf = <int>[];

    _sub = resp.listen(
      (chunk) {
        if (!_running || gen != _gen) return;
        var i = 0;
        while (i < chunk.length) {
          if (state == 0) {
            final take = math.min(remaining, chunk.length - i);
            i += take;
            remaining -= take;
            if (remaining <= 0) state = 1;
          } else if (state == 1) {
            metaLen = chunk[i] * 16;
            i++;
            if (metaLen == 0) {
              state = 0;
              remaining = metaint;
            } else {
              metaBuf.clear();
              state = 2;
            }
          } else {
            final take = math.min(metaLen - metaBuf.length, chunk.length - i);
            metaBuf.addAll(chunk.sublist(i, i + take));
            i += take;
            if (metaBuf.length >= metaLen) {
              _parseMeta(metaBuf);
              state = 0;
              remaining = metaint;
            }
          }
        }
      },
      onError: (_) {
        if (!completer.isCompleted) completer.complete();
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      cancelOnError: true,
    );
    await completer.future;
    if (identical(_connDone, completer)) _connDone = null;
    try {
      await _sub?.cancel();
    } catch (_) {}
    _sub = null;
    client.close(force: true);
  }

  void _parseMeta(List<int> raw) {
    var end = raw.length;
    while (end > 0 && raw[end - 1] == 0) {
      end--;
    }
    if (end == 0) return;
    // latin1 解码后字符下标 == 字节下标，方便回取原始字节
    final text = latin1.decode(raw.sublist(0, end), allowInvalid: true);
    final key = "StreamTitle='";
    final start = text.indexOf(key);
    if (start < 0) return;
    final from = start + key.length;
    final to = text.indexOf("';", from);
    if (to <= from) return;
    var title = _decodeText(raw.sublist(from, to));
    title = title.replaceAll(RegExp(r'[\x00-\x1F]'), '').trim();
    if (title.isEmpty) return;
    onTitle(title);
  }

  // ==== 原始字节的 UTF-8 合法性分析 ====
  //
  // UTF-8 编码规则：
  //   单字节：00-7F（ASCII）
  //   2 字节头：C0-DF，后跟 1 个 80-BF
  //   3 字节头：E0-EF，后跟 2 个 80-BF
  //   4 字节头：F0-F4，后跟 3 个 80-BF
  //
  // GBK 首字节是 81-FE（包括 C0-DF！），如果 UTF-8 strict 解码遇到
  // 连续两个 C0 以上的字节（比如 D5 C5 = GBK "张"），会跳过第一个
  // 产 FFFD，第二个被当成另一个 UTF-8 头——这意味着这段字节不是 UTF-8。
  //
  // 关键洞察：**如果原始字节里超过 40% 无法被 UTF-8 strict 接受，
  // 那这段原始编码就不是 UTF-8**。

  /// 返回 (成功 UTF-8 字节数, 总字节数)
  static (int, int) _analyzeUtf8Validity(List<int> bytes) {
    var validBytes = 0;
    var i = 0;
    while (i < bytes.length) {
      final b = bytes[i];
      // ASCII：00-7F 一定合法
      if (b <= 0x7F) {
        validBytes += 1;
        i += 1;
        continue;
      }
      // 2 字节头：C0-DF
      if (b >= 0xC0 && b <= 0xDF && i + 1 < bytes.length) {
        final b2 = bytes[i + 1];
        if ((b2 & 0xC0) == 0x80) {
          validBytes += 2;
          i += 2;
          continue;
        }
      }
      // 3 字节头：E0-EF
      if (b >= 0xE0 && b <= 0xEF && i + 2 < bytes.length) {
        final b2 = bytes[i + 1];
        final b3 = bytes[i + 2];
        if ((b2 & 0xC0) == 0x80 && (b3 & 0xC0) == 0x80) {
          validBytes += 3;
          i += 3;
          continue;
        }
      }
      // 4 字节头：F0-F4
      if (b >= 0xF0 && b <= 0xF4 && i + 3 < bytes.length) {
        final b2 = bytes[i + 1];
        final b3 = bytes[i + 2];
        final b4 = bytes[i + 3];
        if ((b2 & 0xC0) == 0x80 &&
            (b3 & 0xC0) == 0x80 &&
            (b4 & 0xC0) == 0x80) {
          validBytes += 4;
          i += 4;
          continue;
        }
      }
      // 非法 UTF-8 字节，跳过
      i += 1;
    }
    return (validBytes, bytes.length);
  }

  /// ICY 规范要求 UTF-8，但实际编码很不稳定：
  /// - AsiaFM 亚洲粤语台：GBK 歌名 + UTF-8 括号后缀（**混合编码**，发送端 bug）
  /// - 香港老 Icecast：Big5（繁体中文）
  /// - 其他内地电台：GBK（简体中文）
  /// - 少数新电台：UTF-8
  ///
  /// 策略：
  /// 1. UTF-8 strict 无 FFFD → 直接返回（最干净）
  /// 2. 分析原始字节的 UTF-8 合法性（ASCII + 合法 UTF-8 序列占比）
  ///    - ≥ 50% 合法 → 先试 UTF-8 allowMalformed
  ///      * 如果 FFFD 很少（< 总字符 25%）→ 返回 UTF-8（大部分对）
  ///      * FFFD 太多 → 退回试 Big5 / GBK（说明"看起来合法"是因为 ASCII
  ///        多，真正的中文部分全解不出来）
  ///    - < 50% 合法 → 依次试 Big5、GBK
  /// 3. 最终兜底 Latin-1
  ///
  /// 为什么不看 FFFD 占比直接选？因为 GBK 解码器硬解任何字节都不会产 FFFD，
  /// 但会把 UTF-8 字节两两拼成合法但错误的 GBK 汉字（"亚洲粤语台"→"浜氭床绮よ"）。
  /// 必须结合原始字节分析 + FFFD 占比双重判断。
  static String _decodeText(List<int> bytes) {
    if (bytes.isEmpty) return '';

    // 1. UTF-8 strict：最干净的情况
    try {
      final u8 = utf8.decode(bytes);
      if (!u8.contains('\uFFFD')) return u8;
    } catch (_) {}

    // 2. 原始字节 UTF-8 合法性分析
    final (valid, total) = _analyzeUtf8Validity(bytes);
    final utf8Ratio = total > 0 ? valid / total : 0;

    // 2a. 合法性 ≥ 50% → 先试 UTF-8 allowMalformed
    if (utf8Ratio >= 0.5) {
      final u8m = utf8.decode(bytes, allowMalformed: true);
      // 统计 FFFD 占比
      final totalRunes = u8m.runes.length;
      final fffdCount = u8m.runes.where((c) => c == 0xFFFD).length;
      final fffdRatio = totalRunes > 0 ? fffdCount / totalRunes : 0;
      // FFFD < 25%：大部分字对了 → 接受 UTF-8 结果
      // （AsiaFM 混合编码场景：FFFD 主要在 GBK 歌名部分，UTF-8 括号后缀是对的）
      if (fffdRatio < 0.25) return u8m;
      // FFFD 太多 → 退回试 Big5 / GBK
    }

    // 3. 试 Big5（香港/台湾繁体粤语台首选）
    try {
      final big5 = const Big5Codec().decode(bytes);
      if (!big5.contains('\uFFFD')) return big5;
    } catch (_) {}

    // 4. 试 GBK（内地简体中文最常见）
    try {
      final g = gbk.decode(bytes);
      if (!g.contains('\uFFFD')) return g;
    } catch (_) {}

    // 5. 最终兜底：Latin-1 一字节一字符，永不丢内容
    return latin1.decode(bytes, allowInvalid: true);
  }
}
