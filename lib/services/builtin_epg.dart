import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/epg_source.dart';
import '../models/playlist_source.dart';
import 'builtin_catalog.dart';

/// 内置节目单（央视网 EPG）。
///
/// 频道清单是「内置央视频道」里的央视网那 20 个台；节目单直接从央视网
/// 的公开接口按天取（`d=20261113`），拼成一份本地 XMLTV 缓存。
///
/// 为什么自己拼 XMLTV 而不是引一个第三方 EPG 地址：
/// * 第三方 xmltv 源对央视的台标/台名映射经常对不上，用户看到的是空节目单；
/// * 央视网接口给的 channel id 就是 `cctv1/cctv2/…`，跟内置清单的 tvg-id
///   完全一致，匹配零歧义；
/// * 不依赖外网某个个人维护的节目单站点是否还活着。
///
/// 缓存按天更新（默认 1 天）。用户在 EPG 页仍可自己添加任意 xmltv 源，
/// 内置这个只是「开箱就有节目单」的默认项，随时可以换掉。
class BuiltinEpg {
  BuiltinEpg._();

  /// 作为 EpgSource 接入时的固定 id / 地址
  static const String sourceId = 'omi-builtin-epg';
  static const String localUrl = 'local://builtin-epg';
  static const String displayName = '内置央视节目单';

  static const String _kCache = 'builtin_epg_cache';
  static const String _kAt = 'builtin_epg_at';
  static const String _kDays = 'builtin_epg_interval_days';

  /// 生成后的 XMLTV 文本（没有就返回 null）
  static Future<String?> readCache() async {
    final p = await SharedPreferences.getInstance();
    final s = p.getString(_kCache);
    if (s == null || s.trim().isEmpty) return null;
    return s;
  }

  static Future<DateTime?> fetchedAt() async {
    final p = await SharedPreferences.getInstance();
    final ms = p.getInt(_kAt);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  static Future<int> intervalDays() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_kDays) ?? 1;
  }

  static Future<void> setIntervalDays(int days) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kDays, days.clamp(0, 30));
  }

  /// 缓存里有多少条节目（界面显示用）
  static Future<int> programCount() async {
    final xml = await readCache();
    if (xml == null) return 0;
    return RegExp(r'<programme\b').allMatches(xml).length;
  }

  /// 到期就后台刷一次（启动时调，失败静默）。
  /// 返回是否真的更新了数据——只有更新过才需要让界面重解析。
  static Future<bool> maybeAutoRefresh() async {
    final days = await intervalDays();
    if (days <= 0) return false;
    final at = await fetchedAt();
    final xml = await readCache();
    if (xml != null &&
        at != null &&
        DateTime.now().difference(at).inDays < days) {
      return false;
    }
    final (ok, _) = await refresh();
    return ok;
  }

  /// 抓今天 + 明天两天的节目单，拼成 XMLTV 落地。
  /// 返回 (成功?, 说明)。
  static Future<(bool, String)> refresh({bool force = false}) async {
    if (!force) {
      final days = await intervalDays();
      final at = await fetchedAt();
      final xml = await readCache();
      if (xml != null &&
          days > 0 &&
          at != null &&
          DateTime.now().difference(at).inDays < days) {
        return (true, '当前节目单已是最新');
      }
    }

    // 频道集合取内置清单里的央视网频道（tvg-id 就是接口要的 slug）
    var slugs = _slugsFromM3u(await _readCctvList());
    if (slugs.isEmpty) {
      try {
        slugs = await BuiltinCatalog.fetchSlugs();
      } catch (e) {
        return (false, '取不到频道列表：$e');
      }
    }
    if (slugs.isEmpty) return (false, '没有可用的央视频道');

    final now = DateTime.now();
    final merged = <String, dynamic>{};
    for (final day in [now, now.add(const Duration(days: 1))]) {
      try {
        final data =
            await BuiltinCatalog.fetchEpgRaw(slugs, BuiltinCatalog.ymdOf(day));
        data.forEach((k, v) {
          if (v is! Map) return;
          final target = merged.putIfAbsent(k, () => {
                'channelName': v['channelName'] ?? k,
                'list': <Map>[],
              });
          final list = v['list'];
          if (list is List) {
            (target['list'] as List).addAll(list.whereType<Map>());
          }
        });
      } catch (e) {
        debugPrint('[BuiltinEpg] 取 ${BuiltinCatalog.ymdOf(day)} 失败: $e');
      }
    }

    if (merged.isEmpty) {
      return (false, '央视网节目单接口没有返回数据（网络或接口变动）');
    }

    final xml = _toXmltv(merged, slugs);
    final count = RegExp(r'<programme\b').allMatches(xml).length;
    if (count < 200) {
      return (false, '只取到 $count 条节目，疑似不完整，保留旧节目单');
    }

    final p = await SharedPreferences.getInstance();
    await p.setString(_kCache, xml);
    await p.setInt(_kAt, DateTime.now().millisecondsSinceEpoch);
    return (true, '已更新 ${merged.length} 个频道 / $count 条节目');
  }

  // ==================== 内部 ====================

  static Future<String> _readCctvList() async {
    final p = await SharedPreferences.getInstance();
    final cached = p.getString('builtin_cctv_cache');
    if (cached != null && cached.trim().isNotEmpty) return cached;
    try {
      return await rootBundle.loadString(PlaylistSource.builtinCctvAsset);
    } catch (_) {
      return '';
    }
  }

  static List<String> _slugsFromM3u(String m3u) {
    final re = RegExp(r'tvg-id="(cctv[0-9a-z+]+)"');
    final out = <String>[];
    for (final m in re.allMatches(m3u)) {
      final s = m.group(1)!.toLowerCase();
      if (!out.contains(s)) out.add(s);
    }
    return out;
  }

  static String _toXmltv(Map<String, dynamic> data, List<String> slugs) {
    final buf = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<tv generator-info-name="omi-builtin-epg">');

    for (final slug in slugs) {
      final info = data[slug];
      if (info is! Map) continue;
      final name = (info['channelName'] ?? slug).toString();
      buf.writeln('  <channel id="${_esc(slug)}">');
      buf.writeln('    <display-name>${_esc(name)}</display-name>');
      // 别名：清单里央视频那批台名是「CCTV6」「CCTV-5+」这种纯英数写法，
      // 而央视接口给的是「CCTV-6 电影」。把台号的各种写法都写成
      // display-name，播放器匹配时第 2 步（完整名精确）就能直接命中，
      // 不必依赖字母数字核心的模糊匹配
      for (final alias in _aliases(slug)) {
        if (alias != name) {
          buf.writeln('    <display-name>${_esc(alias)}</display-name>');
        }
      }
      buf.writeln('  </channel>');
    }

    for (final entry in data.entries) {
      final info = entry.value;
      if (info is! Map) continue;
      final list = info['list'];
      if (list is! List) continue;
      for (final raw in list) {
        if (raw is! Map) continue;
        final title = (raw['title'] ?? '').toString().trim();
        final st = (raw['startTime'] as num?)?.toInt() ?? 0;
        final et = (raw['endTime'] as num?)?.toInt() ?? 0;
        if (title.isEmpty || st <= 0 || et <= st) continue;
        buf.writeln('  <programme start="${_xmltvTime(st)}" '
            'stop="${_xmltvTime(et)}" channel="${_esc(entry.key)}">');
        buf.writeln('    <title lang="zh">${_esc(title)}</title>');
        buf.writeln('  </programme>');
      }
    }

    buf.writeln('</tv>');
    return buf.toString();
  }

  /// epoch 秒 → "20261113010200 +0800"（央视节目单是国内时间）
  static String _xmltvTime(int epochSec) {
    final t = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000, isUtc: true)
        .add(const Duration(hours: 8));
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}'
        '${two(t.hour)}${two(t.minute)}${two(t.second)} +0800';
  }

  /// 台号别名：cctv4 → [CCTV-4, CCTV4]，cctv5plus → [CCTV-5+, CCTV5+,
  /// CCTV5PLUS]；cctveurope 这类非数字台返回空（没有通用别名）
  static List<String> _aliases(String slug) {
    final m = RegExp(r'^cctv(\d+)(plus)?$').firstMatch(slug.toLowerCase());
    if (m == null) return const [];
    final n = m.group(1)!;
    final plus = m.group(2) != null;
    if (plus) return ['CCTV-$n+', 'CCTV$n+', 'CCTV${n}PLUS'];
    return ['CCTV-$n', 'CCTV$n'];
  }

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  /// 构造内置 EPG 的源描述（首次启动注入用）
  static EpgSource builtinSource() => EpgSource(
        id: sourceId,
        name: displayName,
        url: localUrl,
        addedAt: DateTime.now(),
      );
}
