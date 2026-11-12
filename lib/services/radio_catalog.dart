import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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

  static Future<List<ChannelCategory>> builtinCategories() async {
    final cached = _builtin;
    if (cached != null) return cached;
    try {
      final raw =
          await rootBundle.loadString(PlaylistSource.builtinRadioAsset);
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

  /// 「我的电台」在前（自己加的优先看到），其后是内置精选各组
  static Future<List<ChannelCategory>> all() async {
    final builtin = await builtinCategories();
    return [...RadioLibrary.buildCategories(), ...builtin];
  }

  /// 已加载过内置目录时，仅重建「我的电台」部分（增删台后调用，不重新读盘）
  static List<ChannelCategory>? rebuildIfLoaded() {
    final builtin = _builtin;
    if (builtin == null) return null;
    return [...RadioLibrary.buildCategories(), ...builtin];
  }
}
