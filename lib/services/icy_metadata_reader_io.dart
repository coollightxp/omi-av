import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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

  /// ICY 规范要求 UTF-8；但港台/东南亚不少电台仍发 GBK，甚至同一
  /// StreamTitle 里**混合两种编码**（AsiaFM 亚洲粤语台实测：歌名是
  /// GBK 的「张国荣」，括号后缀是 UTF-8 的「亚洲粤语台」）。整体用
  /// 任何一种都必然有一半乱码。
  ///
  /// 解法：**分段解码**。
  /// 从左到右尝试 UTF-8 strict 解码，能解多少算多少；遇到非法序列
  /// （非 UTF-8 起始字节）就停下来，把这一小段切出来交给 GBK 解，
  /// 然后继续 UTF-8。交替进行直到整个字节数组处理完。Latin-1 作为
  /// 最终兜底（永不丢字节，至少能显示可读）。
  static String _decodeText(List<int> bytes) {
    if (bytes.isEmpty) return '';

    // 1. 先试整体 UTF-8 strict：如果成功且不含 U+FFFD，这是最干净的情况
    try {
      final u8 = utf8.decode(bytes);
      if (!u8.contains('\uFFFD')) return u8;
    } catch (_) {}

    // 2. 分段解码：交替 UTF-8 strict 和 GBK
    try {
      final buf = StringBuffer();
      int i = 0;
      while (i < bytes.length) {
        // 先尝试 UTF-8 strict：从当前位置往后找最长的、UTF-8 合法的前缀
        final utf8End = _findUtf8PrefixEnd(bytes, i);
        if (utf8End > i) {
          buf.write(utf8.decode(bytes.sublist(i, utf8End)));
          i = utf8End;
        }
        if (i >= bytes.length) break;

        // 剩下的开头是 GBK 字节（非 UTF-8 起始），用 GBK 解
        // 贪心：尝试 1-4 字节的 GBK 前缀，解到能解的位置
        final gbkEnd = _findGbkPrefixEnd(bytes, i);
        if (gbkEnd > i) {
          buf.write(gbk.decode(bytes.sublist(i, gbkEnd)));
          i = gbkEnd;
        } else {
          // 两者都解不了，用 Latin-1 硬解 1 字节跳过
          buf.writeCharCode(bytes[i]);
          i++;
        }
      }
      final mixed = buf.toString();
      if (mixed.isNotEmpty) return mixed;
    } catch (_) {}

    // 3. 最终兜底：整体 GBK
    try {
      final g = gbk.decode(bytes);
      if (g.isNotEmpty) return g;
    } catch (_) {}

    // 4. 最后兜底：Latin-1 一字节一字符，永不丢内容
    return latin1.decode(bytes, allowInvalid: true);
  }

  /// 从 [start] 开始，往后找最长的 UTF-8 strict 合法前缀。
  /// 返回这个前缀的**结束位置**（ exclusive）。
  ///
  /// UTF-8 合法起始字节：0xxxxxxx (ASCII) 或 110xxxxx / 1110xxxx / 11110xxx。
  /// 多字节序列后续字节必须是 10xxxxxx。
  static int _findUtf8PrefixEnd(List<int> bytes, int start) {
    int i = start;
    while (i < bytes.length) {
      final b = bytes[i];
      if (b < 0x80) {
        // ASCII 单字节
        i++;
      } else if ((b & 0xE0) == 0xC0) {
        // 2 字节序列：C0-DF + 1 个 continuation
        if (i + 1 < bytes.length && (bytes[i + 1] & 0xC0) == 0x80) {
          i += 2;
        } else {
          break;
        }
      } else if ((b & 0xF0) == 0xE0) {
        // 3 字节序列：E0-EF + 2 个 continuation
        if (i + 2 < bytes.length &&
            (bytes[i + 1] & 0xC0) == 0x80 &&
            (bytes[i + 2] & 0xC0) == 0x80) {
          i += 3;
        } else {
          break;
        }
      } else if ((b & 0xF8) == 0xF0 && b <= 0xF4) {
        // 4 字节序列：F0-F4 + 3 个 continuation
        if (i + 3 < bytes.length &&
            (bytes[i + 1] & 0xC0) == 0x80 &&
            (bytes[i + 2] & 0xC0) == 0x80 &&
            (bytes[i + 3] & 0xC0) == 0x80) {
          i += 4;
        } else {
          break;
        }
      } else {
        // 非 UTF-8 起始（比如 GBK 的 0x81-0xFE 首字节，或续字节 0x80-0xBF
        // 在不该出现的位置）——说明这里应该切到 GBK
        break;
      }
    }
    return i;
  }

  /// 从 [start] 开始，往后找一个 GBK 合法的字符前缀结束位置。
  /// GBK 规则：首字节 0x81-0xFE；如果首字节在 0x40-0x7E 或 0x80-0xFE 之间，
  /// 就是 2 字节；否则是单字节 ASCII。
  ///
  /// 这里的目标只是**解出第一个 GBK 字符**，让外层循环继续判断后面的
  /// 字节是不是又回到了 UTF-8。
  static int _findGbkPrefixEnd(List<int> bytes, int start) {
    if (start >= bytes.length) return start;
    final b = bytes[start];
    if (b >= 0x81 && b <= 0xFE) {
      // 首字节：可能是 0x40-0x7E 或 0x80-0xFE（0x7F 是非法的半角）
      if (start + 1 < bytes.length) {
        final b2 = bytes[start + 1];
        if ((b2 >= 0x40 && b2 <= 0x7E) || (b2 >= 0x80 && b2 <= 0xFE)) {
          return start + 2;
        }
      }
      // GBK 半角字符（A1-A9 开头 + A1-FE）——也是 2 字节
      if (start + 1 < bytes.length &&
          b >= 0xA1 && b <= 0xA9 &&
          bytes[start + 1] >= 0xA1 && bytes[start + 1] <= 0xFE) {
        return start + 2;
      }
      // 兜底：先把首字节吃掉，让循环继续
      return start + 1;
    }
    // 非 GBK 首字节（ASCII 或 continuation byte），先吞 1 字节
    return start + 1;
  }
}
