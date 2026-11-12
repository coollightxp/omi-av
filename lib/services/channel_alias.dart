import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/channel.dart';

/// 频道/电台别名（方案 12.3 第一档）。
///
/// 个性化显示名：只改「显示」，不动源数据。列表抽屉、电台播放页、
/// 底部信息板、右侧节目单、通知栏/锁屏统一走 [displayName] 生效。
class ChannelAlias {
  ChannelAlias._();

  static const _kKey = 'omi_channel_alias_v1';

  static final Map<String, String> _map = <String, String>{};
  static bool _loaded = false;

  static bool get loaded => _loaded;

  /// 全量别名表（管理页用），id → 别名
  static Map<String, String> get entries => Map.unmodifiable(_map);

  static String? aliasOf(String id) => _map[id];

  /// 显示名：有别名用别名，否则用原名
  static String displayName(Channel ch) => _map[ch.id] ?? ch.name;

  static bool hasAlias(Channel ch) => _map.containsKey(ch.id);

  static Future<void> ensure() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_kKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        decoded.forEach((k, v) {
          if (k is String && v is String && v.trim().isNotEmpty) {
            _map[k] = v.trim();
          }
        });
      }
    } catch (e) {
      debugPrint('[ChannelAlias] load failed: $e');
    }
  }

  /// 设置/清除别名（alias 为空串或 null 即清除）
  static Future<void> setAlias(String id, String? alias) async {
    final a = alias?.trim() ?? '';
    if (a.isEmpty) {
      if (_map.remove(id) == null) return;
    } else {
      if (_map[id] == a) return;
      _map[id] = a;
    }
    await _persist();
  }

  static Future<void> _persist() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kKey, jsonEncode(_map));
    } catch (e) {
      debugPrint('[ChannelAlias] save failed: $e');
    }
  }
}
