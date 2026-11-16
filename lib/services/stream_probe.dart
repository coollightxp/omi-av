import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/channel.dart';

/// 直播流可用性探测。
///
/// 内置清单（电台精选）由上游维护，隔一阵就有台悄悄下线（404/410）。清单
/// 更新原先只校验「文件格式对不对」（有无 #EXTINF、条目数、链接像不像地址），
/// 从没校验「每一路流还能不能播」，于是死台一直挂在列表里，点进去无声。
///
/// 这里给每路 http(s) 流做一次轻量探测（GET 头一小段就断开）：
/// - 有效 → 正常显示；
/// - **连续 2 次**失败 → 标记不可用，列表里隐藏，但**清单里原样保留**。
///   以后哪天这路流恢复，下一次探测通过就自动回到列表——不删数据，
///   免得「今天死了、明天又活了」的台被永久丢掉。
///
/// 单次失败不算死：本机网络抖动、对端短暂限流都会造成一次超时，一次就
/// 藏掉会误杀能播的台。成功一次即清零，所以判定是「最近两次都不通」。
class StreamProbe {
  StreamProbe._();

  static const String _kResults = 'stream_probe_results_v1';

  /// 结果保鲜期（天）：超过就重新探一次。台随时上下线，结果不能一直用
  static const int freshDays = 3;

  /// 连续失败多少次才认定不可用
  static const int deadThreshold = 2;

  /// 连续失效多少天后彻底撤掉（列表不再显示、日常不再探测；清单文本
  /// 仍保留）。用户口径：挂半年「失效」标没意义，就是这源废了。想再验证
  /// 点「检测可用性」（force 会连撤掉的一起探），通过就自动回来
  static const int purgeAfterDays = 30;

  /// 一轮探测的失败率超过这个比例（且样本够多）就判「本机网络/对端异常」，
  /// 整轮结果作废。否则一次断网会把所有台累计成死台，30 天后被集体撤掉
  static const double _massFailRatio = 0.6;
  static const int _massFailMin = 8;

  /// 出厂时已确认下线的源（首次安装、还没跑过探测时先用它挡一下，
  /// 免得死台在列表里露面几十秒）。一旦探测出结果就以探测结果为准：
  /// 这些源哪天恢复，探测通过就自动回到列表，不会被永久封杀
  static const Set<String> _factoryDead = {
    'https://lhttp-hw.qtfm.cn/live/5022379/64k.mp3', // 星空电台（qtfm 已下架）
    'https://lhttp-hw.qtfm.cn/live/5022107/64k.mp3', // 动听音乐台（qtfm 已下架）
  };

  static const Duration _timeout = Duration(seconds: 8);

  /// 并发数：60 路电台 ÷ 6 ≈ 10 轮，最坏 80 秒探完，后台跑不挡界面
  static const int _concurrency = 6;

  /// 收到多少字节就认定「服务器认这路流」。
  /// 不能设大：央广几路 HLS 的主清单只有 235～249 字节，阈值取 256
  /// 会把活台判死（实测误杀 5 路）。64 字节已能区分「有数据」和
  /// 「200 但空 body（要特定 UA 才给流）」
  static const int _aliveBytes = 64;

  /// 列表里是否隐藏「确认不可用」的源（设置项；控制器初始化时同步过来，
  /// 两个列表过滤点直接读它，免得把设置对象层层传下去）
  static bool hideUnavailable = true;

  static final Map<String, _ProbeEntry> _results = {};
  static bool _loaded = false;
  static bool _running = false;

  /// 有探测结果落库后的回调：控制器挂上去重建列表（电台目录 / 电视列表）
  static void Function()? onChanged;

  static bool get running => _running;

  // ==================== 结果存取 ====================

  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_kResults);
      if (raw == null || raw.trim().isEmpty) return;
      final map = jsonDecode(raw);
      if (map is! Map) return;
      map.forEach((k, v) {
        if (v is! Map) return;
        _results['$k'] = _ProbeEntry(
          ok: v['ok'] == true,
          fails: (v['fails'] as num?)?.toInt() ?? 0,
          at: DateTime.fromMillisecondsSinceEpoch(
              (v['at'] as num?)?.toInt() ?? 0),
          firstFailAt: (v['ff'] as num?) == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch((v['ff'] as num).toInt()),
        );
      });
    } catch (e) {
      debugPrint('[StreamProbe] load failed: $e');
    }
  }

  static Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
        _kResults,
        jsonEncode({
          for (final e in _results.entries)
            e.key: {
              'ok': e.value.ok,
              'fails': e.value.fails,
              'at': e.value.at.millisecondsSinceEpoch,
              if (e.value.firstFailAt != null)
                'ff': e.value.firstFailAt!.millisecondsSinceEpoch,
            },
        }),
      );
    } catch (e) {
      debugPrint('[StreamProbe] save failed: $e');
    }
  }

  /// 该地址是否已判定「不可用」（连续失败达阈值）
  static bool isDead(String url) {
    final key = url.trim();
    final e = _results[key];
    // 还没探过：出厂已知下线的先挡（探测跑过就以结果为准）
    if (e == null) return _factoryDead.contains(key);
    return !e.ok && e.fails >= deadThreshold;
  }

  /// 是否已「撤掉」：连续失效超过 30 天，这源基本废了，不再显示也不再
  /// 参与日常探测（清单文本仍保留，想验证点手动检测即可）
  static bool isPurged(String url) {
    final e = _results[url.trim()];
    if (e == null || e.ok) return false;
    if (e.fails < deadThreshold) return false;
    final since = e.firstFailAt ?? e.at;
    return DateTime.now().difference(since).inDays >= purgeAfterDays;
  }

  /// 某地址最近一次探测结果（null = 没探过 / 已过期）
  static bool? lastResult(String url) {
    final e = _results[url.trim()];
    if (e == null) return null;
    if (DateTime.now().difference(e.at).inDays >= freshDays) return null;
    return e.ok;
  }

  /// 上次探测时间（设置页显示「上次检测：…」）
  static DateTime? lastProbedAt() {
    DateTime? latest;
    for (final e in _results.values) {
      if (latest == null || e.at.isAfter(latest)) latest = e.at;
    }
    return latest;
  }

  /// 统计一批频道的探测情况（设置页 / 扫码页展示用）
  static (int available, int dead, int unknown) summarize(
      List<Channel> channels) {
    var available = 0, dead = 0, unknown = 0;
    for (final ch in channels) {
      if (ch.streamUrls.isEmpty || ch.isWebPage) continue;
      for (final u in ch.streamUrls) {
        if (!_isProbeable(u)) continue;
        final r = lastResult(u);
        if (r == null) {
          unknown++;
        } else if (r) {
          available++;
        } else if (isDead(u)) {
          dead++;
        } else {
          // 失败一次但还没达阈值：先算可用（可能只是抖动）
          available++;
        }
      }
    }
    return (available, dead, unknown);
  }

  // ==================== 过滤 ====================

  /// 列表过滤：把「确认不可用」的流从频道里摘掉；多源频道只要还有一条
  /// 活的就保留（只去掉死的那些）；全死的整个台隐藏。分类变空也跟着去掉，
  /// 免得列表里留一堆空标题。
  static List<ChannelCategory> filterCategories(List<ChannelCategory> cats) {
    if (!hideUnavailable) return cats;
    final out = <ChannelCategory>[];
    for (final c in cats) {
      final kept = <Channel>[];
      for (final ch in c.channels) {
        // 网页频道（webview）与无地址条目不动：它们不是直连流，探测口径不同
        if (ch.streamUrls.isEmpty || ch.isWebPage) {
          kept.add(ch);
          continue;
        }
        final alive = <String>[
          for (final u in ch.streamUrls)
            if (!isDead(u)) u,
        ];
        if (alive.isEmpty) continue; // 全部不通：这台先不显示
        kept.add(alive.length == ch.streamUrls.length
            ? ch
            : ch.copyWith(streamUrls: alive));
      }
      if (kept.isNotEmpty) out.add(c.copyWith(channels: kept));
    }
    return out;
  }

  // ==================== 探测 ====================

  /// 探测一批频道里「没探过 / 结果过期」的流（[force] = 全部重探）。
  /// 返回实际探测的地址数；0 表示没有需要探的（或已有探测在跑）。
  static Future<int> probeChannels(List<Channel> channels,
      {bool force = false}) async {
    if (_running) return 0;
    await ensureLoaded();

    final jobs = <_ProbeJob>[];
    final seen = <String>{};
    for (final ch in channels) {
      if (ch.streamUrls.isEmpty || ch.isWebPage) continue;
      for (final raw in ch.streamUrls) {
        final url = raw.trim();
        if (!_isProbeable(url) || !seen.add(url)) continue;
        if (!force && lastResult(url) != null) continue; // 结果还新
        // 已撤掉的台日常不再探（省流量）：要验证走手动「检测可用性」
        if (!force && isPurged(url)) continue;
        jobs.add(_ProbeJob(url, ch.userAgent, ch.httpReferer));
      }
    }
    if (jobs.isEmpty) return 0;

    _running = true;
    // 先收集、整轮判完再落库：一整轮里绝大多数都失败时，几乎肯定是本机
    // 断网/对端挂了，不是这些台真死了。照单全收会把好台也累计成死台，
    // 30 天后被集体撤掉
    final fresh = <String, bool>{};
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= jobs.length) return;
        final j = jobs[i];
        fresh[j.url] = await _probeOne(j.url, ua: j.ua, referer: j.referer);
      }
    }

    try {
      await Future.wait(
          [for (var i = 0; i < _concurrency; i++) worker()]);
    } finally {
      _running = false;
    }

    final failed = fresh.values.where((ok) => !ok).length;
    if (fresh.length >= _massFailMin &&
        failed / fresh.length > _massFailRatio) {
      debugPrint('[StreamProbe] 本轮 $failed/${fresh.length} 失败，'
          '判定为本机网络/对端异常，结果作废');
      return 0;
    }

    final now = DateTime.now();
    for (final e in fresh.entries) {
      final prev = _results[e.key];
      if (e.value) {
        _results[e.key] =
            _ProbeEntry(ok: true, fails: 0, at: now, firstFailAt: null);
      } else {
        _results[e.key] = _ProbeEntry(
          ok: false,
          // 成功清零；失败在原先次数上累加（达阈值才隐藏）
          fails: (prev?.fails ?? 0) + 1,
          at: now,
          // 连续失败起点：上一轮还活着（或首次失败）就从现在算，
          // 一直失败就沿用最早那次
          firstFailAt:
              (prev != null && !prev.ok) ? (prev.firstFailAt ?? now) : now,
        );
      }
    }
    await _save();
    // 结果进库：让列表按新的可用性重建
    try {
      onChanged?.call();
    } catch (e) {
      debugPrint('[StreamProbe] onChanged failed: $e');
    }
    return fresh.length;
  }

  static bool _isProbeable(String url) {
    final u = url.trim().toLowerCase();
    return u.startsWith('http://') || u.startsWith('https://');
  }

  /// 单路探测：GET 取头部一小段就断。返回是否可用。
  ///
  /// 判定口径刻意宽松，只判「服务器认不认这路流」：404/410（下架）、
  /// 401/403（防盗链拦截）、连接不上 → 不可用；其余只要吐了数据就算活。
  /// 不判码率/编码，那属于播放器的事，探得太严会误杀低码率老台。
  static Future<bool> _probeOne(String url,
      {String ua = '', String referer = ''}) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return true; // 地址都解析不了：交给播放器报错，别在这判死
    final client = http.Client();
    try {
      final req = http.Request('GET', uri);
      req.headers['User-Agent'] = ua.isNotEmpty
          ? ua
          // 多数电台 CDN 对 Dart 默认 UA 会直接 403，用浏览器 UA 探
          : 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
      if (referer.isNotEmpty) req.headers['Referer'] = referer;
      // 只取头 64KB：够判断服务器给不给数据，也不至于把整段音频拉下来
      req.headers['Range'] = 'bytes=0-65535';
      final resp = await client.send(req).timeout(_timeout);
      final code = resp.statusCode;
      // 416 = 请求的范围超出资源长度：资源是存在的，只是比 64KB 短，
      // 绝不能按失败算（小清单/短音频会踩到）
      if (code == 416) return true;
      if (code >= 400) {
        // 4xx 明确拒绝；5xx 算暂时性故障，也按不可用计（连续两次才隐藏）
        return false;
      }
      return await _drainSome(resp.stream).timeout(_timeout, onTimeout: () => false);
    } catch (_) {
      return false;
    } finally {
      try {
        client.close();
      } catch (_) {}
    }
  }

  /// 读到 [_aliveBytes] 就返回 true 并断开（避免把直播流一直拉着）
  static Future<bool> _drainSome(Stream<List<int>> stream) async {
    var got = 0;
    try {
      await for (final chunk in stream) {
        got += chunk.length;
        if (got >= _aliveBytes) return true;
      }
    } catch (_) {
      // 提前断开/解码错误：只要已经拿到足够字节，就说明流是活的
    }
    return got >= _aliveBytes;
  }
}

class _ProbeEntry {
  final bool ok;
  final int fails;
  final DateTime at;

  /// 连续失败从什么时候开始（判「失效多久」用；成功即清空）
  final DateTime? firstFailAt;

  const _ProbeEntry({
    required this.ok,
    required this.fails,
    required this.at,
    this.firstFailAt,
  });
}

class _ProbeJob {
  final String url;
  final String ua;
  final String referer;

  const _ProbeJob(this.url, this.ua, this.referer);
}
