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

  /// ICY 规范要求 UTF-8，但港台/东南亚电台实际编码很不稳定：
  /// - AsiaFM 亚洲粤语台一会儿发 GBK 歌名 + UTF-8 括号后缀（混合），
  ///   一会儿发全 UTF-8 但把 3 字节序列的第三字节截成问号或空格
  ///   （发送端 bug，不是我们能修的）。
  /// - 别的电台可能全 GBK、全 UTF-8，ISO-8859-1 也见过。
  ///
  /// 评分策略不行——GBK 把 UTF-8 字节两两拼成合法 GBK 汉字，Unicode 码点
  /// 也在 CJK 范围，CFFD 占比低（因为只有 UTF-8 strict 才产 FFFD），
  /// 选 GBK 会把"何嘉涓"变成"浣曞槈涓"（字全错了但看起来"也是中文"）。
  ///
  /// 改用 **U+FFFD 占比**判断：
  /// 1. UTF-8 strict 无 U+FFFD → 直接返回（最干净）
  /// 2. UTF-8 allowMalformed：统计 U+FFFD 占总字符比例
  ///    - ≤ 25% → 选 UTF-8（发送端本来想发 UTF-8，截断是 bug，大部分字对）
  ///    - > 25% → 说明大部分字节不是 UTF-8 → 试 GBK
  /// 3. GBK 解成功且不乱 → 选 GBK
  /// 4. 最终兜底 Latin-1
  static String _decodeText(List<int> bytes) {
    if (bytes.isEmpty) return '';

    // 1. UTF-8 strict：如果成功且不含 U+FFFD，最干净的情况
    try {
      final u8 = utf8.decode(bytes);
      if (!u8.contains('\uFFFD')) return u8;
    } catch (_) {}

    // 2. UTF-8 allowMalformed：统计 U+FFFD 占比
    final String u8m;
    try {
      u8m = utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      u8m = latin1.decode(bytes, allowInvalid: true); // 先随便给个
    }

    final totalChars = u8m.runes.length;
    if (totalChars > 0) {
      final fffdCount = u8m.runes.where((c) => c == 0xFFFD).length;
      final fffdRatio = fffdCount / totalChars;
      // U+FFFD ≤ 25%：发送端主要是 UTF-8，只有少量截断 → 选 UTF-8
      if (fffdRatio <= 0.25) return u8m;
    }

    // 3. U+FFFD 太多 → 试 GBK
    try {
      final g = gbk.decode(bytes);
      // GBK 里的 U+FFFD 通常意味着 fl_charset 遇到非法字节
      if (!g.contains('\uFFFD')) return g;
      // GBK 也有 U+FFFD → 比较哪个少
      final gFf = g.runes.where((c) => c == 0xFFFD).length;
      final u8Ff = u8m.runes.where((c) => c == 0xFFFD).length;
      if (gFf < u8Ff) return g;
    } catch (_) {}

    // 4. 最终兜底：Latin-1 一字节一字符，永不丢内容
    return latin1.decode(bytes, allowInvalid: true);
  }
}
