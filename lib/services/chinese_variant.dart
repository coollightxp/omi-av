import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

/// 歌词简繁转换（OpenCC 词表 + 字表，双级）。
///
/// 为什么不用单纯的逐字映射：简→繁存在大量「一简对多繁」
/// （发→發/髮、后→後/后、面→麵/面），按字硬转会把「头发」转成
/// 「頭發」。这里按 OpenCC 的分层思路：先按**词组表**做最长匹配
/// （STPhrases/TSPhrases，词组的转换结果是人工校对的），剩下的
/// 单字再走**字表**（STCharacters/TSCharacters）兜底。
///
/// 四份词表来自 OpenCC（Apache-2.0），随安装包发布，只在第一次
/// 用到转换时读一次，之后常驻内存（总共约 5.5 万条映射）。
class ChineseVariantConverter {
  ChineseVariantConverter._();

  static final ChineseVariantConverter instance = ChineseVariantConverter._();

  /// 显示模式（与 `PlayerSettings.lyricsVariant` 对应）：
  /// 0 = 原文，1 = 转简体，2 = 转繁体
  static const int modeOriginal = 0;
  static const int modeSimplified = 1;
  static const int modeTraditional = 2;

  static const String _s2tPhrasesAsset = 'assets/opencc/STPhrases.txt';
  static const String _s2tCharsAsset = 'assets/opencc/STCharacters.txt';
  static const String _t2sPhrasesAsset = 'assets/opencc/TSPhrases.txt';
  static const String _t2sCharsAsset = 'assets/opencc/TSCharacters.txt';

  /// 词组最长匹配上限（OpenCC 词表最长词条在 12 字以内）
  static const int _maxPhraseLen = 12;

  bool _loaded = false;
  bool get loaded => _loaded;

  Future<void>? _loading;

  /// 词组表（key = 原词组，value = 转换结果），先于字表做最长匹配
  final Map<String, String> _s2tPhrases = <String, String>{};
  final Map<String, String> _t2sPhrases = <String, String>{};

  /// 字表（单字兜底）
  final Map<String, String> _s2tChars = <String, String>{};
  final Map<String, String> _t2sChars = <String, String>{};

  Future<void> ensureLoaded() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    try {
      await _loadDict(_s2tPhrasesAsset, _s2tPhrases);
      await _loadDict(_s2tCharsAsset, _s2tChars);
      await _loadDict(_t2sPhrasesAsset, _t2sPhrases);
      await _loadDict(_t2sCharsAsset, _t2sChars);
      _loaded = true;
    } catch (e) {
      debugPrint('[ChineseVariant] 词表加载失败: $e');
    }
  }

  /// OpenCC 词典格式：`词条\t转换结果`（结果多候选时空格分隔，
  /// 第一个是 OpenCC 语义下最常用的，取它）
  Future<void> _loadDict(String asset, Map<String, String> out) async {
    final raw = await rootBundle.loadString(asset);
    for (final line in const LineSplitter().convert(raw)) {
      if (line.isEmpty || line.startsWith('#')) continue;
      final i = line.indexOf('\t');
      if (i <= 0) continue;
      final key = line.substring(0, i);
      final vals = line.substring(i + 1).trim().split(RegExp(r'\s+'));
      if (key.isEmpty || vals.isEmpty || vals.first.isEmpty) continue;
      out[key] = vals.first;
    }
  }

  /// 歌词文本按 [mode] 转换；原文模式/词表未加载完时原样返回
  String convert(String text, int mode) {
    if (mode == modeSimplified) {
      return _loaded ? _convert(text, _t2sPhrases, _t2sChars) : text;
    }
    if (mode == modeTraditional) {
      return _loaded ? _convert(text, _s2tPhrases, _s2tChars) : text;
    }
    return text;
  }

  /// 贪心最长匹配：每个位置先试词组（从最长往下），命不中再查单字。
  /// 查不到映射的字符（英数、符号、生僻字）原样保留。
  String _convert(
      String text, Map<String, String> phrases, Map<String, String> chars) {
    if (text.isEmpty) return text;
    final sb = StringBuffer();
    var i = 0;
    final n = text.length;
    while (i < n) {
      var matched = false;
      final maxLen = n - i < _maxPhraseLen ? n - i : _maxPhraseLen;
      for (var len = maxLen; len >= 2; len--) {
        final rep = phrases[text.substring(i, i + len)];
        if (rep != null) {
          sb.write(rep);
          i += len;
          matched = true;
          break;
        }
      }
      if (matched) continue;
      final ch = text[i];
      sb.write(chars[ch] ?? ch);
      i += 1;
    }
    return sb.toString();
  }
}
