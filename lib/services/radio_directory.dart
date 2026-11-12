import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/radio_station.dart';

/// 在线电台目录（Radio Browser）。
///
/// 与 LX-FM 的做法一致：不在设置页常驻一个"电台源"，而是给一个
/// 搜索入口——搜到哪台就加哪台，加进本地的「我的电台」库。
///
/// Radio Browser 是社区维护的公开目录，有多个镜像；这里逐个回退，
/// 全部失败才报错。搜索走 `name=`（支持中文），标签走 `tagList=`
/// （只认英文标签，界面上给中文名、内部转英文）。
class RadioDirectory {
  RadioDirectory._();

  static const List<String> _hosts = [
    'https://de1.api.radio-browser.info',
    'https://at1.api.radio-browser.info',
    'https://nl1.api.radio-browser.info',
  ];

  /// 地名快捷搜索：用户想的是"听听上海的台"，不是"上海"这两个字。
  /// 点一下就把地名填进搜索框按名称匹配（多数中国台台名里带城市/省份）。
  static const List<String> quickRegions = [
    '北京',
    '上海',
    '广东',
    '浙江',
    '江苏',
    '四川',
    '湖南',
    '湖北',
    '山东',
    '河南',
    '陕西',
    '福建',
  ];

  /// 快捷标签：中文给人看，英文给接口用
  static const List<(String, String)> quickTags = [
    ('新闻', 'news'),
    ('音乐', 'music'),
    ('交通', 'traffic'),
    ('故事', 'talk'),
    ('戏曲', 'opera'),
    ('体育', 'sports'),
    ('财经', 'business'),
    ('怀旧', 'oldies'),
  ];

  /// 搜索电台。
  ///
  /// [query] 为空且 [tag] 也为空时返回中国区热门台（相当于"随便看看"）。
  /// [cnOnly] 只在有关键词时生效：限制在中国区，避免搜"音乐"出来
  /// 一堆国外台。
  static Future<List<RadioStation>> search({
    String query = '',
    String tag = '',
    bool cnOnly = true,
    int limit = 60,
  }) async {
    final params = <String, String>{
      'limit': '$limit',
      'hidebroken': 'true',
      'order': 'clickcount',
      'reverse': 'true',
    };
    if (query.trim().isNotEmpty) params['name'] = query.trim();
    if (tag.isNotEmpty) params['tagList'] = tag;
    if (cnOnly && (query.trim().isNotEmpty || tag.isNotEmpty)) {
      params['countrycode'] = 'CN';
    }
    if (query.trim().isEmpty && tag.isEmpty) {
      // 默认页：中国区热门
      params['countrycode'] = 'CN';
    }

    Object? lastError;
    for (final host in _hosts) {
      try {
        final uri = Uri.parse('$host/json/stations/search')
            .replace(queryParameters: params);
        final resp = await http.get(uri, headers: {
          'User-Agent': 'OmiPlayer/1.0'
        }).timeout(const Duration(seconds: 12));
        if (resp.statusCode != 200) {
          lastError = 'HTTP ${resp.statusCode}';
          continue;
        }
        final list = jsonDecode(utf8.decode(resp.bodyBytes)) as List;
        final out = <RadioStation>[];
        for (final item in list) {
          if (item is! Map) continue;
          final url = (item['url_resolved'] ?? item['url'] ?? '').toString();
          final name = (item['name'] ?? '').toString().trim();
          if (url.isEmpty || name.isEmpty) continue;
          out.add(RadioStation(
            id: (item['stationuuid'] ?? url).toString(),
            name: name,
            url: url,
            favicon: (item['favicon'] ?? '').toString(),
            tags: (item['tags'] ?? '').toString(),
            country: (item['country'] ?? '').toString(),
            codec: (item['codec'] ?? '').toString(),
            bitrate: (item['bitrate'] as num?)?.toInt() ?? 0,
            clickCount: (item['clickcount'] as num?)?.toInt() ?? 0,
          ));
        }
        // 同名台去重（保留点击量最高的第一条，接口已按点击量倒序）
        final seen = <String>{};
        final uniq = <RadioStation>[];
        for (final s in out) {
          final key = s.name.trim().toLowerCase();
          if (!seen.add(key)) continue;
          uniq.add(s);
        }
        return uniq;
      } catch (e) {
        lastError = e;
        debugPrint('[RadioDirectory] $host failed: $e');
      }
    }
    throw Exception('在线电台目录暂时连不上（$lastError）');
  }
}
