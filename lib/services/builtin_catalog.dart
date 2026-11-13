import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/radio_station.dart';
import 'radio_directory.dart';

/// 内置清单抓取器：央视网频道 / 在线电台。
///
/// 内置的「央视网-央视频道」不是抄死的清单，而是**从央视网直播页现抓**：
///
/// | 步骤 | 地址 | 作用 |
/// |---|---|---|
/// | 1 | `tv.cctv.com/live/` | 抓频道页里的 `/live/cctvN/` 链接 → slug 列表 |
/// | 2 | `api.cntv.cn/epg/getEpgInfoByChannelNew` | 用 slug 换频道中文名（顺带取节目单） |
///
/// 站点平时不改版就不用动；一旦改版（新增/下线频道、换路径），App 定时
/// 抓一次就自动同步，不需要重新发版、也不依赖任何外部托管仓库。
///
/// 本类只负责「抓 + 解析 + 组装成 m3u 文本」，落盘和定时在
/// `SourceManager` 里；节目单部分见 `builtin_epg.dart`。
class BuiltinCatalog {
  BuiltinCatalog._();

  static const String livePage = 'https://tv.cctv.com/live/';
  static const String epgApi =
      'https://api.cntv.cn/epg/getEpgInfoByChannelNew';

  /// 央视网分组名（与出厂 asset 保持一致，解析器按分组归类）
  static const String groupCctv = '央视网-央视频道';

  static const Map<String, String> _headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36',
    'Accept': 'text/html,application/json,*/*',
  };

  // ==================== 抓取 ====================

  /// 央视网直播页里的频道 slug：cctv1 … cctv17 / cctv5plus / cctveurope …
  ///
  /// 页面导航是静态渲染的（不是 JS 拼的），正则足够；抓到后按频道号排序，
  /// 保证清单顺序稳定，不会因为一次抓取把顺序打乱。
  static Future<List<String>> fetchSlugs() async {
    final resp = await http
        .get(Uri.parse(livePage), headers: _headers)
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}');
    }
    final html = utf8.decode(resp.bodyBytes, allowMalformed: true);
    final re = RegExp(r'/live/(cctv[0-9a-z+]+)/');
    final set = <String>{};
    for (final m in re.allMatches(html)) {
      final slug = m.group(1)!.toLowerCase();
      // 排除只有 "cctv" 没有编号的路径段
      if (RegExp(r'\d').hasMatch(slug)) set.add(slug);
    }
    final list = set.toList()..sort(_compareSlug);
    return list;
  }

  /// 接口单次最多带约 12 个频道，超过就直接回
  /// `{"errcode":"1001","msg":"params error"}`（实测 15 个必失败）。
  /// 之前一次把 20 个 slug 全塞进去，等于一次都没成功——这就是
  /// 「内置节目单一条节目都没有」的根因。
  static const int _epgBatch = 10;

  /// 取节目单原始数据（同时带 channelName，用来给频道起名）
  ///
  /// [ymd] 形如 20261113；接口只提供「今天 / 明天」两天。
  /// 内部按 [_epgBatch] 分批请求并合并；某一批失败时逐个补偿一次，
  /// 单个频道取不到不影响其它频道。
  static Future<Map<String, dynamic>> fetchEpgRaw(
    List<String> slugs,
    String ymd,
  ) async {
    if (slugs.isEmpty) return <String, dynamic>{};
    final merged = <String, dynamic>{};
    for (var i = 0; i < slugs.length; i += _epgBatch) {
      final batch = slugs.sublist(
          i, i + _epgBatch > slugs.length ? slugs.length : i + _epgBatch);
      try {
        merged.addAll(await _fetchEpgBatch(batch, ymd));
      } catch (e) {
        // 整批失败：逐个再试，坏 slug 不连累同批的好台
        debugPrint('[BuiltinCatalog] 批次失败 ${batch.join(",")}: $e');
        for (final one in batch) {
          try {
            merged.addAll(await _fetchEpgBatch([one], ymd));
          } catch (_) {
            // 这个台今天没有节目单，跳过
          }
        }
      }
    }
    return merged;
  }

  static Future<Map<String, dynamic>> _fetchEpgBatch(
    List<String> slugs,
    String ymd,
  ) async {
    final uri = Uri.parse(
        '$epgApi?c=${slugs.join(',')}&serviceId=tvcctv&d=$ymd');
    final resp = await http
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 25));
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true));
    if (decoded is! Map) throw Exception('返回格式不对');
    final data = decoded['data'];
    if (data is! Map) {
      throw Exception('接口返回 ${decoded['msg'] ?? decoded['errcode'] ?? '空数据'}');
    }
    return data.cast<String, dynamic>();
  }

  // ==================== 组装 ====================

  /// 抓取并重建「央视网-央视频道」分组。
  ///
  /// [current] 是当前生效的清单文本（缓存或出厂 asset）。只有央视网那 20 条
  /// 会重新生成，**「央视频」的卫视频道 / 央视频道 60 多条原样保留**——
  /// 那两组的 pid 是央视频内部编号，抓不到，只能随包走。
  ///
  /// 返回 (成功?, 说明, 新清单文本)。
  static Future<(bool, String, String?)> buildCctvList(String current) async {
    List<String> slugs;
    try {
      slugs = await fetchSlugs();
    } catch (e) {
      return (false, '抓取央视网直播页失败：$e', null);
    }
    // 站点改版时宁可不动，也不要用半截结果覆盖能用的清单
    if (slugs.length < 10) {
      return (false, '央视网直播页结构可能有变：只解析到 ${slugs.length} 个频道', null);
    }

    var raw = <String, dynamic>{};
    try {
      raw = await fetchEpgRaw(slugs, ymdOf(DateTime.now()));
    } catch (e) {
      // 名称拿不到也能出清单：退化成 slug 大写，节目单另由 BuiltinEpg 抓
      debugPrint('[BuiltinCatalog] 取频道名失败: $e');
    }

    final buf = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln('# Omi 内置央视频道（央视网 tv.cctv.com）')
      ..writeln('# 「央视网-央视频道」由 App 定时从央视网直播页抓取生成；')
      ..writeln('# 「央视频-*」两组随安装包发布。全部为 webview:// 网页频道，')
      ..writeln('# 由内置 WebView 打开官方直播页，不解析流地址，不会因签名过期失效。')
      ..writeln('# 清单抓取时间 ${DateTime.now()}');

    for (final slug in slugs) {
      final info = raw[slug];
      var name = info is Map ? (info['channelName'] ?? '').toString().trim() : '';
      if (name.isEmpty) name = slug.toUpperCase();
      buf.writeln(
          '#EXTINF:-1 tvg-id="$slug" group-title="$groupCctv",${prettyName(name)}');
      buf.writeln('webview://tv.cctv.com/live/$slug/');
    }

    final kept = _keepOtherGroups(current);
    buf.write(kept);

    final text = buf.toString();
    final total = _countEntries(text);
    if (total < 40) {
      return (false, '新清单只有 $total 个台，疑似抓取残缺，已放弃', null);
    }
    return (true, '已从央视网同步 ${slugs.length} 个央视频道（共 $total 个台）', text);
  }

  /// 抓取并补充内置电台清单。
  ///
  /// 电台跟电视不同：央视网没有"电台频道页"可抓，内置那 60 个台是手工挑的
  /// （电视伴音、央广、省市台），质量比自动抓的高。所以这里只做**增量**——
  /// 从 Radio Browser 的中国区热门台里挑没收录过的补进来，绝不删除已有台，
  /// 用户不会遇到"升级完常听的台没了"。
  ///
  /// 返回 (成功?, 说明, 新清单文本)；没有新台时文本为 null（不必写盘）。
  static Future<(bool, String, String?)> buildRadioList(String current) async {
    List<RadioStation> stations;
    try {
      stations = await RadioDirectory.search(limit: 80);
    } catch (e) {
      return (false, '在线电台目录连不上：$e', null);
    }
    if (stations.isEmpty) {
      return (false, '在线电台目录没有返回结果', null);
    }

    // 已有台名（归一化），避免重复收录
    final existing = <String>{};
    for (final line in current.split('\n')) {
      if (!line.trimLeft().startsWith('#EXTINF')) continue;
      final i = line.lastIndexOf(',');
      if (i > 0) {
        final k = _normName(line.substring(i + 1));
        if (k.isNotEmpty) existing.add(k);
      }
    }

    final added = <RadioStation>[];
    for (final st in stations) {
      final url = st.url.trim();
      if (url.isEmpty || !url.startsWith('http')) continue;
      // 码率太低的多半是无人维护的台，宁可少加
      if (st.bitrate > 0 && st.bitrate < 48) continue;
      final codec = st.codec.toUpperCase();
      if (codec.isNotEmpty &&
          codec != 'MP3' &&
          codec != 'AAC' &&
          codec != 'AAC+') {
        continue;
      }
      final name = st.name.trim();
      final key = _normName(name);
      if (name.isEmpty || key.isEmpty || existing.contains(key)) continue;
      existing.add(key);
      added.add(st);
      if (added.length >= 40) break;
    }

    if (added.isEmpty) {
      return (true, '电台清单已是最新（没有新台）', null);
    }

    final buf = StringBuffer(current.trimRight())
      ..writeln()
      ..writeln('# ===== 网络电台（自动补充 ${DateTime.now().toString().split(' ').first}）=====');
    for (final st in added) {
      final logo = st.favicon.trim();
      final tags = st.tags.trim();
      buf.writeln('#EXTINF:-1 group-title="网络电台" radio="true"'
          '${logo.isEmpty ? '' : ' tvg-logo="$logo"'}'
          '${tags.isEmpty ? '' : ' tvg-tags="$tags"'},${st.name.trim()}');
      buf.writeln(st.url.trim());
    }

    return (true, '已补充 ${added.length} 个网络电台', buf.toString());
  }

  /// 台名归一化：忽略空格、连字符、中英文标点，只比"字"
  static String _normName(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[\s\-_（）()\[\].·、,，+:：|/]'), '');

  /// 保留非央视网分组（央视频 卫视频道 / 央视频道）的 EXTINF + 地址行
  static String _keepOtherGroups(String text) {
    final lines = text.split('\n');
    final out = StringBuffer();
    var i = 0;
    while (i < lines.length) {
      final line = lines[i].trimRight();
      if (!line.startsWith('#EXTINF')) {
        i++;
        continue;
      }
      final isCctvGroup = line.contains('group-title="$groupCctv"');
      // 找紧跟的第一条非注释行作为地址
      var j = i + 1;
      while (j < lines.length && lines[j].trim().isEmpty) {
        j++;
      }
      final url = j < lines.length ? lines[j].trim() : '';
      if (!isCctvGroup && url.isNotEmpty && !url.startsWith('#')) {
        out.writeln(line);
        out.writeln(url);
      }
      i = j + 1;
    }
    return out.toString();
  }

  static int _countEntries(String text) => text
      .split('\n')
      .where((l) => l.trimLeft().startsWith('#EXTINF'))
      .length;

  // ==================== 小工具 ====================

  static String ymdOf(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}'
      '${t.month.toString().padLeft(2, '0')}'
      '${t.day.toString().padLeft(2, '0')}';

  /// "CCTV-16奥林匹克" → "CCTV-16 奥林匹克"（数字与汉字之间补空格）
  static String prettyName(String name) =>
      name.replaceAllMapped(RegExp(r'(\d)(?=[\u4e00-\u9fa5])'),
          (m) => '${m.group(1)} ');

  /// 频道号排序：cctv1 < cctv2 < … < cctv17 < cctv5plus < cctvamerica
  static int _compareSlug(String a, String b) {
    int numOf(String s) {
      final m = RegExp(r'\d+').firstMatch(s);
      return m == null ? 9999 : int.parse(m.group(0)!);
    }

    final na = numOf(a);
    final nb = numOf(b);
    if (na != nb) return na.compareTo(nb);
    final sa = a.replaceAll(RegExp(r'\d+'), '');
    final sb = b.replaceAll(RegExp(r'\d+'), '');
    return sa.compareTo(sb);
  }
}
