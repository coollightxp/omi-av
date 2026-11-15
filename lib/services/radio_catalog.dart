import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/channel.dart';
import '../models/playlist_source.dart';
import 'playlist_parser.dart';
import 'radio_library.dart';

/// 电台目录：把「内置精选」和「我的电台」合成一份给左侧频道列表用。
///
/// 为什么不让它走 SourceManager：内置精选是一个独立播放源，切源会连带
/// 换掉电视列表、打断正在看的台。左侧的「电台」标签只想"顺手翻一下"，
/// 所以这里直接解析安装包里的 m3u（一次，缓存住），与当前源无关。
///
/// 播放仍是 `controller.playChannel(channel)`，不改变当前源。
class RadioCatalog {
  RadioCatalog._();

  static List<ChannelCategory>? _builtin;

  static List<ChannelCategory>? get cachedBuiltin => _builtin;

  /// 丢掉已解析的内置目录（清单更新后重读用）
  static void invalidate() => _builtin = null;

  static Future<List<ChannelCategory>> builtinCategories() async {
    final cached = _builtin;
    if (cached != null) return cached;
    try {
      // 优先读「内置电台清单更新」落下的缓存（与 SourceManager 同一 key），
      // 没有才回落到安装包资源——否则设置里点了「更新电台清单」，
      // 左侧电台列表永远还是出厂那一份
      String? raw;
      try {
        final prefs = await SharedPreferences.getInstance();
        raw = prefs.getString('builtin_radio_cache');
      } catch (_) {
        // prefs 不可用：直接走资源
      }
      if (raw == null || raw.trim().isEmpty) {
        raw = await rootBundle.loadString(PlaylistSource.builtinRadioAsset);
      }
      final cats = PlaylistParser.parse(raw, PlaylistFormat.m3u);
      // 分组顺序按 m3u 里出现顺序（电视伴音 → 央广 → 省市 → 音乐 → 故事）
      _builtin = cats;
      return cats;
    } catch (e) {
      debugPrint('[RadioCatalog] builtin load failed: $e');
      _builtin = const [];
      return const [];
    }
  }

  /// 「我的电台」在前（自己加的优先看到），其后是内置精选各组。
  ///
  /// [tvChannels] 为当前电视源频道：给了就顺带做一次「电视伴音」
  /// 自动匹配（方案 12.6 第一组）。
  static Future<List<ChannelCategory>> all({
    List<Channel> tvChannels = const [],
  }) async {
    final builtin = await builtinCategories();
    return _merge(tvChannels: tvChannels, builtin: builtin);
  }

  /// 已加载过内置目录时，仅重建可变部分（增删台/切源后调用，不重读安装包）
  static List<ChannelCategory>? rebuildIfLoaded({
    List<Channel> tvChannels = const [],
  }) {
    final builtin = _builtin;
    if (builtin == null) return null;
    return _merge(tvChannels: tvChannels, builtin: builtin);
  }

  static List<ChannelCategory> _merge({
    required List<Channel> tvChannels,
    required List<ChannelCategory> builtin,
  }) {
    final cats = [...RadioLibrary.buildCategories(), ...builtin];
    return withTvCompanion(cats, tvChannels);
  }

  /// 电视伴音自动匹配（方案 12.6 第一组）。
  ///
  /// 拿电视频道名去**已导入的电台源**里找同名独立音频流，匹配到的才进组，
  /// 台标与 EPG 标识继承电视（列表行第二行就能显示该电视的节目）。
  ///
  /// 只做规范化**同名**匹配，不做模糊包含：「新闻台」「音乐台」这类泛名
  /// 一模糊就会配错台，宁可少匹配也不要错配。
  static List<ChannelCategory> withTvCompanion(
    List<ChannelCategory> cats,
    List<Channel> tvChannels,
  ) {
    if (tvChannels.isEmpty) return cats;
    final byName = <String, Channel>{};
    for (final c in cats) {
      for (final ch in c.channels) {
        byName.putIfAbsent(tvKey(ch.name), () => ch);
      }
    }
    // 内置精选里已有的伴音台不再重复添加
    final existing = <String>{};
    for (final c in cats) {
      if (!c.name.contains('电视伴音')) continue;
      for (final ch in c.channels) {
        existing.add(ch.id);
      }
    }

    final matched = <Channel>[];
    for (final t in tvChannels) {
      if (t.isRadio || t.streamUrls.isEmpty || t.isWebPage) continue;
      final key = tvKey(t.name);
      if (key.length < 3) continue;
      final r = byName[key];
      if (r == null || existing.contains(r.id)) continue;
      existing.add(r.id);
      matched.add(r.copyWith(
        // 前缀避免与电台原型共用 id（收藏/历史按 id 存）
        id: 'companion:${r.id}',
        name: t.name,
        logoUrl: t.logoUrl.isNotEmpty ? t.logoUrl : r.logoUrl,
        tvgId: t.tvgId.isNotEmpty ? t.tvgId : r.tvgId,
        tvgName: t.tvgName.isNotEmpty ? t.tvgName : r.tvgName,
        groupTitle: '电视伴音',
      ));
    }
    if (matched.isEmpty) return cats;

    final idx = cats.indexWhere((e) => e.name.contains('电视伴音'));
    if (idx >= 0) {
      final g = cats[idx];
      final out = List<ChannelCategory>.from(cats);
      out[idx] = g.copyWith(channels: [...matched, ...g.channels]);
      return out;
    }
    return [
      ChannelCategory(
        id: 'radio:tv-companion',
        name: '电视伴音',
        channels: matched,
      ),
      ...cats,
    ];
  }

  /// 台名规范化：去空格/标点，统一 CCTV 写法，去掉「伴音/广播/FM」后缀。
  /// CCTV-1 综合 / 中央电视台综合 / cctv1综合 → cctv1综合
  static String tvKey(String raw) {
    var t = raw.toLowerCase();
    t = t.replaceAll(RegExp(r'[\s\-_·・.,，。、:：()（）\[\]【】]'), '');
    t = t.replaceAll('中央电视台', 'cctv').replaceAll('央视', 'cctv');
    t = t.replaceAll('伴音', '').replaceAll('广播', '').replaceAll('fm', '');
    return t.trim();
  }
}
