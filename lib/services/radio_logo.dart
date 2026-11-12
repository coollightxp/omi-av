import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/channel.dart';

/// 电台台标补全（三级策略的第二级）。
///
/// 优先级（由 ChannelBadge 串起来）：
/// 1. 源里写死的 `tvg-logo` / 本地内置 `assets/logos`
/// 2. 本服务：Radio Browser 按台名匹配 favicon（一次全量拉取 + 本地缓存）
/// 3. 界面生成的字母台标（深蓝底 + 白色首字）
///
/// 为什么全量拉一次而不是逐台查：频道列表一屏 20+ 行，逐台请求等于
/// 开局打几十个 HTTP，既慢又容易被限流。Radio Browser 支持一次返回
/// 上千台，把「台名 → favicon」建成索引，列表查表即可、零请求。
class RadioLogo {
  RadioLogo._();

  static const String _cacheKey = 'omi_radio_logo_map';
  static const String _cacheTimeKey = 'omi_radio_logo_time';
  static const Duration _ttl = Duration(days: 7);

  /// Radio Browser 有多个镜像，任何一个通了就行
  static const List<String> _hosts = [
    'https://de1.api.radio-browser.info',
    'https://at1.api.radio-browser.info',
    'https://nl1.api.radio-browser.info',
  ];

  /// 可信图床白名单：电台/电视台官方或主流音频平台的图片服务。
  /// 不在名单里的一律丢弃，回落到字母台标
  static const List<String> _logoHosts = [
    'qtfm.cn', // 蜻蜓图床（国内电台台标最全）
    'qingting.fm',
    'cnr.cn', // 央广
    'radio.cn',
    'cri.cn',
    'cctv.com', // 央视
    'cctvpic.com',
    'gdtv.cn', // 广东广电
    'ajmide.com', // 阿基米德（上海台）
    'myalicdn.com', // 央视伴音 CDN
    'xmcdn.com', // 喜马拉雅
    'asiafm.net',
  ];

  static bool _trustedLogo(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return false;
    }
    // 明确的网站图标不是台标
    if (uri.path.toLowerCase().endsWith('favicon.ico')) return false;
    final host = uri.host.toLowerCase();
    return _logoHosts.any((h) => host == h || host.endsWith('.$h'));
  }

  static Map<String, String>? _map;
  static Future<void>? _loading;

  /// 已建好的索引（未加载完成时为空表，界面直接走字母台标）
  static Map<String, String> get index => _map ?? const {};

  static bool get ready => _map != null;

  /// 启动时调用一次，不 await：失败/超时都静默，台标只是锦上添花
  static Future<void> ensure() => _loading ??= _load();

  static Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    // 1. 先用缓存（有就先能显示，再决定要不要后台刷新）
    final cached = prefs.getString(_cacheKey);
    if (cached != null && cached.isNotEmpty) {
      try {
        final decoded = jsonDecode(cached) as Map<String, dynamic>;
        _map = decoded.map((k, v) => MapEntry(k, v as String));
      } catch (_) {
        _map = null;
      }
    }
    final stamp = prefs.getInt(_cacheTimeKey) ?? 0;
    final fresh = DateTime.now().millisecondsSinceEpoch - stamp <
        _ttl.inMilliseconds;
    if (_map != null && fresh) return;

    // 2. 缓存缺失或过期：后台拉一次（不阻塞界面）
    final fetched = await _fetch();
    if (fetched.isEmpty) return; // 拉失败保留旧缓存
    _map = fetched;
    try {
      await prefs.setString(_cacheKey, jsonEncode(fetched));
      await prefs.setInt(
          _cacheTimeKey, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
      // 缓存写失败不影响本次使用
    }
  }

  static Future<Map<String, String>> _fetch() async {
    for (final host in _hosts) {
      try {
        final uri = Uri.parse('$host/json/stations/search'
            '?countrycode=CN&order=clickcount&reverse=true'
            '&limit=1200&hidebroken=true');
        final resp = await http
            .get(uri, headers: {'User-Agent': 'OmiPlayer/1.0'})
            .timeout(const Duration(seconds: 12));
        if (resp.statusCode != 200) continue;
        final list = jsonDecode(utf8.decode(resp.bodyBytes)) as List;
        final map = <String, String>{};
        for (final item in list) {
          if (item is! Map) continue;
          final name = (item['name'] ?? '').toString().trim();
          final favicon = (item['favicon'] ?? '').toString().trim();
          if (name.isEmpty || favicon.isEmpty) continue;
          // 广播库的 favicon 是用户随手填的，大量指向网站图标
          // （微博 appicon、sinaimg、xx.com/favicon.ico）。这类图放进
          // 列表比字母台标脏得多，宁可不要——只认已知的电台/电视台图床
          if (!_trustedLogo(favicon)) continue;
          final key = normalize(name);
          // 同名多台时保留点击量更高的（列表已按 clickcount 倒序）
          map.putIfAbsent(key, () => favicon);
        }
        if (map.isNotEmpty) return map;
      } catch (e) {
        debugPrint('[RadioLogo] fetch $host failed: $e');
      }
    }
    return const {};
  }

  /// 按频道名查台标；查不到返回空串
  static String logoFor(Channel channel) {
    final map = _map;
    if (map == null || map.isEmpty) return '';
    // 台名、tvg-name 都试一遍：后者常是更规范的电台名
    for (final raw in [channel.name, channel.tvgName]) {
      final key = normalize(raw);
      if (key.isEmpty) continue;
      final hit = map[key];
      if (hit != null) return hit;
      // 去掉「FM97.4」这类频率尾巴再试一次：
      // 源里写「北京音乐广播 FM97.4」，广播库里只叫「北京音乐广播」
      final stripped = _stripFreq(key);
      if (stripped != key) {
        final hit2 = map[stripped];
        if (hit2 != null) return hit2;
      }
      // 前缀匹配兜底：只在长度差 >= 3 时启用，避免「音乐」串到「音乐之声」
      for (final e in map.entries) {
        if (e.key.length >= 3 &&
            (key.startsWith(e.key) || e.key.startsWith(key)) &&
            (key.length - e.key.length).abs() >= 2) {
          return e.value;
        }
      }
    }
    return '';
  }

  static final RegExp _freqRe =
      RegExp(r'(fm|am|调频)?\d+(\.\d+)?$', caseSensitive: false);

  static String _stripFreq(String s) =>
      s.replaceAll(_freqRe, '').replaceAll(_spaceRe, '');

  static final RegExp _spaceRe = RegExp(r'\s+');

  /// 归一化：小写、去空白、全角转半角、去常见分隔符与「广播/电台」后缀。
  /// 与 ChannelLogo.normalize 保持同一套规则，但额外削掉台名尾巴，
  /// 因为广播库的命名比电视源随意得多。
  static String normalize(String raw) {
    var s = raw
        .toLowerCase()
        .replaceAll('（', '(')
        .replaceAll('）', ')')
        .replaceAll(_spaceRe, '')
        .replaceAll('-', '')
        .replaceAll('_', '')
        .replaceAll('·', '')
        .replaceAll('•', '')
        .replaceAll(RegExp(r'[\s\-—]+'), '');
    // 括号里的补充说明（如「(高清)」「【2023】」）不参与匹配
    s = s.replaceAll(RegExp(r'[\(（][^\)）]*[\)）]'), '');
    s = s.replaceAll(RegExp(r'[\[【][^\]】]*[\]】]'), '');
    return s;
  }
}
