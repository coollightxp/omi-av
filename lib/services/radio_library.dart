import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/channel.dart';
import '../models/radio_station.dart';
import '../models/playlist_source.dart';

/// 「我的电台」本地库。
///
/// 在线目录里搜到的台，加进来就存这里（SharedPreferences 里的一个
/// JSON 数组），并在源列表里对应一条固定的「我的电台」源。
/// 不走文件系统：几十条电台用 prefs 足够，也免了路径/权限问题。
class RadioLibrary {
  RadioLibrary._();

  static const String _key = 'omi_radio_library';
  static const String categoryName = '我的电台';

  static List<RadioStation> _items = [];
  static bool _loaded = false;

  static List<RadioStation> get items => List.unmodifiable(_items);
  static bool get isLoaded => _loaded;
  static bool get isEmpty => _items.isEmpty;

  static bool contains(String stationId) =>
      _items.any((e) => e.id == stationId);

  static Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List;
        _items = list
            .whereType<Map<String, dynamic>>()
            .map(RadioStation.fromJson)
            .toList();
      }
    } catch (e) {
      debugPrint('[RadioLibrary] load failed: $e');
      _items = [];
    }
    _loaded = true;
  }

  static Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(_items.map((e) => e.toJson()).toList()),
    );
  }

  /// 加入电台；已存在返回 false
  static Future<bool> add(RadioStation s) async {
    if (contains(s.id)) return false;
    _items = [..._items, s];
    await _save();
    return true;
  }

  static Future<bool> remove(String stationId) async {
    final before = _items.length;
    _items = _items.where((e) => e.id != stationId).toList();
    if (_items.length == before) return false;
    await _save();
    return true;
  }

  /// 转成频道分类，供 SourceManager 与电视源同一套流程消费
  static List<ChannelCategory> buildCategories() {
    if (_items.isEmpty) return const [];
    return [
      ChannelCategory(
        id: PlaylistSource.radioLibraryId,
        name: categoryName,
        channels: [
          for (int i = 0; i < _items.length; i++) _toChannel(_items[i], i + 1),
        ],
      ),
    ];
  }

  static Channel _toChannel(RadioStation s, int number) => Channel(
        // 前缀避免和电视源里同名频道的 id 撞车（收藏/历史按 id 存）
        id: 'myradio:${s.id}',
        name: s.name,
        streamUrls: [s.url],
        logoUrl: s.favicon,
        categoryId: PlaylistSource.radioLibraryId,
        groupTitle: categoryName,
        channelType: ChannelType.radio,
      );
}
