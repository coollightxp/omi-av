import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/playlist_source.dart';

/// 内置电台精选的索引（出厂自带的那 60 个台）。
///
/// 用途只有一个：在「在线电台」搜索结果里，判断某个台是不是**已经内置**——
/// 已内置的台不该再让用户重复加一份到「我的电台」，否则列表里会出现
/// 两个同名台、收藏/历史也会分裂成两条。
///
/// 只在首次用到时读一次安装包内的 m3u，几十 KB，之后纯内存比对。
class BuiltinRadioIndex {
  BuiltinRadioIndex._();

  static final Set<String> _urls = {};
  static final Set<String> _names = {};
  static bool _loaded = false;
  static bool _loading = false;

  static bool get isLoaded => _loaded;

  static Future<void> ensure() async {
    if (_loaded || _loading) return;
    _loading = true;
    try {
      final raw = await rootBundle.loadString(PlaylistSource.builtinRadioAsset);
      _parse(raw);
      _loaded = true;
    } catch (e) {
      debugPrint('[BuiltinRadioIndex] load failed: $e');
    } finally {
      _loading = false;
    }
  }

  static void _parse(String raw) {
    for (final line in const LineSplitter().convert(raw)) {
      final t = line.trim();
      if (t.isEmpty || t.startsWith('#')) {
        if (t.startsWith('#EXTINF')) {
          final comma = t.indexOf(',');
          if (comma > 0) {
            final n = _normName(t.substring(comma + 1));
            if (n.isNotEmpty) _names.add(n);
          }
        }
        continue;
      }
      _urls.add(_normUrl(t));
    }
  }

  /// 在线目录里的这个台，内置精选里有没有
  static bool contains({required String name, required String url}) {
    if (_loaded) {
      if (_urls.contains(_normUrl(url))) return true;
      final n = _normName(name);
      if (n.isEmpty) return false;
      if (_names.contains(n)) return true;
      // 「中国之声」vs「中国之声 FM」这类：短的一方至少 4 个字才认可，
      // 避免「新闻」「音乐」这种泛词互相误判
      if (n.length >= 4) {
        for (final b in _names) {
          if (b.length >= 4 && (b.contains(n) || n.contains(b))) return true;
        }
      }
    }
    return false;
  }

  static String _normUrl(String u) {
    var s = u.trim().toLowerCase();
    final q = s.indexOf('?');
    if (q > 0) s = s.substring(0, q);
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  static String _normName(String s) {
    var t = s.toLowerCase();
    t = t.replaceAll(RegExp(r'[\s\-_·・.,，。、:：()（）\[\]【】"“”]'), '');
    // 「中国之声FM」「FM98.7 交通广播」这类后缀/前缀不影响是不是同一个台
    t = t.replaceAll('fm', '').replaceAll('广播', '');
    return t.trim();
  }
}
