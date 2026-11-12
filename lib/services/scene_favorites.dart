import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 场景制收藏（方案 12.3 第一档）。
///
/// 收藏从单列表升级为多场景分组（新闻 / 音乐 / 戏曲…），电视频道同样
/// 适用：收藏动作落在「当前场景」，场景间切列表即一键换组。
///
/// 老数据（单列表收藏 `omi_favorite_channel_ids`）首次读取时整体迁移进
/// 默认场景「我的收藏」，不丢任何已收藏频道。
class SceneFavorites {
  SceneFavorites._();

  static const _kKey = 'omi_scene_favorites_v1';
  static const legacyKey = 'omi_favorite_channel_ids';

  /// 默认场景：兼容老数据，也作为未选场景时的收藏落点
  static const String defaultScene = '我的收藏';

  static final List<String> _names = <String>[defaultScene];
  static final Map<String, Set<String>> _ids = <String, Set<String>>{
    defaultScene: <String>{},
  };
  static String _active = defaultScene;
  static bool _loaded = false;

  static bool get loaded => _loaded;

  /// 全部场景名（保持创建顺序，默认场景恒为第一个）
  static List<String> get sceneNames => List.unmodifiable(_names);

  /// 当前场景（收藏动作的落点）
  static String get activeScene => _active;

  static void setActive(String name) {
    if (_names.contains(name)) _active = name;
  }

  static Set<String> idsIn(String scene) => _ids[scene] ?? const <String>{};

  static int countIn(String scene) => idsIn(scene).length;

  /// 频道是否被任一场景收藏（星标亮灭口径）
  static bool contains(String channelId) =>
      _ids.values.any((s) => s.contains(channelId));

  /// 频道所在的第一个场景（null = 未收藏）
  static String? sceneOf(String channelId) {
    for (final n in _names) {
      if (_ids[n]?.contains(channelId) ?? false) return n;
    }
    return null;
  }

  /// 所有场景的频道 id 并集（启动恢复等老口径兼容）
  static List<String> get allIds {
    final out = <String>{};
    for (final s in _ids.values) {
      out.addAll(s);
    }
    return out.toList(growable: false);
  }

  static Future<void> ensure() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_kKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final scenes = decoded['scenes'];
          final active = decoded['active'];
          if (scenes is List) {
            _names.clear();
            _ids.clear();
            for (final e in scenes) {
              if (e is Map && e['name'] is String) {
                final name = e['name'] as String;
                if (_names.contains(name)) continue;
                _names.add(name);
                final ids = e['ids'];
                _ids[name] = ids is List
                    ? ids.whereType<String>().toSet()
                    : <String>{};
              }
            }
            if (_names.isEmpty) {
              _names.add(defaultScene);
              _ids[defaultScene] = <String>{};
            }
            if (active is String && _names.contains(active)) {
              _active = active;
            } else {
              _active = _names.first;
            }
          }
        }
      } else {
        // 老版本迁移：单列表收藏 → 默认场景
        final legacy = p.getStringList(legacyKey) ?? const <String>[];
        if (legacy.isNotEmpty) {
          _ids[defaultScene] = legacy.toSet();
          await _persist();
        }
      }
    } catch (e) {
      debugPrint('[SceneFavorites] load failed: $e');
    }
  }

  /// 把频道加入场景
  static Future<void> add(String scene, String channelId) async {
    final ids = _ids[scene];
    if (ids == null || ids.contains(channelId)) return;
    ids.add(channelId);
    await _persist();
  }

  /// 从所有场景移除（取消收藏 = 彻底取消，不留在某个组里）
  static Future<bool> removeFromAll(String channelId) async {
    var removed = false;
    for (final s in _ids.values) {
      if (s.remove(channelId)) removed = true;
    }
    if (removed) await _persist();
    return removed;
  }

  static Future<void> createScene(String name) async {
    final n = name.trim();
    if (n.isEmpty || _names.contains(n)) return;
    _names.add(n);
    _ids[n] = <String>{};
    // 新场景立即成为收藏落点：用户建完就想往里收台
    _active = n;
    await _persist();
  }

  static Future<void> renameScene(String oldName, String newName) async {
    final n = newName.trim();
    if (!_names.contains(oldName) ||
        n.isEmpty ||
        n == oldName ||
        _names.contains(n)) {
      return;
    }
    final idx = _names.indexOf(oldName);
    _names[idx] = n;
    _ids[n] = _ids.remove(oldName) ?? <String>{};
    if (_active == oldName) _active = n;
    await _persist();
  }

  /// 删除场景（组内收藏一并清除；至少保留一个场景）
  static Future<void> deleteScene(String name) async {
    if (_names.length <= 1 || !_names.contains(name)) return;
    _names.remove(name);
    _ids.remove(name);
    if (_active == name) _active = _names.first;
    await _persist();
  }

  static Future<void> _persist() async {
    try {
      final p = await SharedPreferences.getInstance();
      final payload = jsonEncode({
        'active': _active,
        'scenes': [
          for (final n in _names) {'name': n, 'ids': _ids[n]?.toList() ?? []},
        ],
      });
      await p.setString(_kKey, payload);
    } catch (e) {
      debugPrint('[SceneFavorites] save failed: $e');
    }
  }
}
