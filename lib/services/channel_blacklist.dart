import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/channel.dart';

/// 频道/电台黑名单（方案 12.3 第一档）。
///
/// 按**关键词**匹配台名或分组名（不区分大小写，包含即命中），
/// 例如「购物」「测试」「戏曲」。
///
/// 只影响**上下换台时自动跳过**，列表里仍然可见、可手动点播——
/// 手动选中是明确意图，不该被拦。
class ChannelBlacklist {
  ChannelBlacklist._();

  static const _kKey = 'channel_blacklist_v1';

  static final List<String> _keys = <String>[];
  static bool _loaded = false;

  static bool get loaded => _loaded;

  static List<String> get keywords => List.unmodifiable(_keys);

  static bool get isEmpty => _keys.isEmpty;

  static Future<void> ensure() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final list = p.getStringList(_kKey) ?? const <String>[];
      _keys
        ..clear()
        ..addAll(list.where((e) => e.trim().isNotEmpty));
    } catch (e) {
      debugPrint('[ChannelBlacklist] load failed: $e');
    }
  }

  /// 是否命中黑名单：台名或分组名包含任一关键词
  static bool blocks(Channel ch) {
    if (_keys.isEmpty) return false;
    final name = ch.name.toLowerCase();
    final group = ch.groupTitle.toLowerCase();
    for (final k in _keys) {
      if (name.contains(k) || group.contains(k)) return true;
    }
    return false;
  }

  static Future<void> add(String keyword) async {
    final k = keyword.trim().toLowerCase();
    if (k.isEmpty || _keys.contains(k)) return;
    _keys.add(k);
    await _persist();
  }

  static Future<void> remove(String keyword) async {
    if (_keys.remove(keyword)) await _persist();
  }

  static Future<void> clear() async {
    if (_keys.isEmpty) return;
    _keys.clear();
    await _persist();
  }

  static Future<void> _persist() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_kKey, _keys);
    } catch (e) {
      debugPrint('[ChannelBlacklist] save failed: $e');
    }
  }
}
