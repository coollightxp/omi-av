import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'chinese_variant.dart';

/// 一行歌词（时间轴 = 歌词内标注的「第几秒唱」）
@immutable
class LyricsLine {
  const LyricsLine(this.time, this.text);

  final Duration time;
  final String text;
}

/// 一首歌的歌词（可能带时间轴，也可能是纯文本）
@immutable
class LyricsDoc {
  const LyricsDoc({
    required this.title,
    required this.artist,
    required this.lines,
    this.synced = true,
    this.duration,
  });

  final String title;
  final String artist;
  final List<LyricsLine> lines;

  /// 是否带时间轴：纯文本歌词没有时间戳，只能整段展示、不做逐句点亮
  final bool synced;

  /// 词库里标注的标准时长（用于版本甄别，顺带能反推切歌点）
  final Duration? duration;

  bool get isEmpty => lines.isEmpty;
}

/// ICY 曲名拆出来的两个字段
@immutable
class IcyTitle {
  const IcyTitle(this.track, this.artist);

  final String track;
  final String artist;

  String get display => artist.isEmpty ? track : '$artist - $track';
}

/// 电台逐句歌词（待办 L）。
///
/// 设计要点（2026-11-18 与用户逐条定稿）：
/// - **词源**：两级，查到即停——LRCLIB（免费、无 Key、带 LRC 时间轴）
///   查不到/只有空壳时，兜底 LrcAPI 公共实例 `api.lrc.cx`（聚合酷狗/
///   网易云/咪咕，中文覆盖好，实测能查到 LRCLIB 空壳的中文歌）；
/// - **锚点**：曲名变化那一刻记下播放位置 = 新歌第 0 秒，误差偏慢、不累积；
/// - **中途进台**：进台第一首不知道唱到哪，歌词照显示但不点亮，下一首起精确同步；
/// - **切台**：显示意图跨台记忆（想不想看是用户选择），歌词数据随台清空；
/// - **无曲名台**：曲名恒为文件名/从不变化 → 面板按钮置灰（那是台的能力缺失）。
///
/// 单例 + [ChangeNotifier]：播放页/面板直接监听，不经过 PlayerController
/// 的大范围 notifyListeners（避免整棵播放树重建）。
class RadioLyrics extends ChangeNotifier {
  RadioLyrics._();

  static final RadioLyrics instance = RadioLyrics._();

  static const String _ua =
      'OmiPlayer (https://github.com/coollightxp/omi-av)';
  static const String _api = 'https://lrclib.net/api';

  /// 设置开关（「电台歌词显示」）。关闭时功能完全不存在。
  bool _enabled = false;
  bool get enabled => _enabled;

  /// 当次显示意图：跨台记忆。开关关闭时强制 false。
  bool _visible = true;
  bool get visible => _visible;

  LyricsDoc? _doc;
  LyricsDoc? get doc => _doc;

  /// 原始歌词文档（词源给的原文）——[_doc] 是按简繁转换设置加工后
  /// 的显示版本，转换设置变化时从它重新生成，不重新查词
  LyricsDoc? _rawDoc;

  bool _querying = false;
  bool get querying => _querying;

  bool _notFound = false;
  bool get notFound => _notFound;

  /// 当前曲名（已清洗）；空 = 这个台还没推过有效曲名 → 按钮置灰
  String _raw = '';
  String get currentTrack => _raw;

  bool get hasTrack => _raw.isNotEmpty;

  /// 锚点是否已知（中途进台的第一首为 false：不点亮、不滚动）
  bool _hasAnchor = false;
  bool get hasAnchor => _hasAnchor;

  Duration _anchorPos = Duration.zero;

  /// 进台第一首（不知道唱到哪）——用于顶部提示
  bool _midJoined = false;
  bool get midJoined => _midJoined;

  int _titleSeen = 0;
  String? _channelId;

  /// 在途请求代际号：切台/切歌后旧响应直接丢弃
  int _gen = 0;

  /// 曲名 → 歌词（null 表示查过了确实没有，避免反复请求）
  final Map<String, LyricsDoc?> _cache = <String, LyricsDoc?>{};

  /// 两万条上限的简单保护，防止长时间挂机内存无界
  static const int _cacheLimit = 200;

  // ==================== 外部输入 ====================

  /// 设置开关变化
  void setEnabled(bool v) {
    if (_enabled == v) return;
    _enabled = v;
    _visible = v; // 开 = 默认显示；关 = 功能不存在
    if (v && _raw.isNotEmpty) unawaited(_ensureFetch());
    notifyListeners();
  }

  /// 面板按钮：当次显示/隐藏（用户意图，跨台记忆）
  void toggleVisible() {
    if (!_enabled) return;
    _visible = !_visible;
    if (_visible && _raw.isNotEmpty && _doc == null && !_notFound) {
      unawaited(_ensureFetch());
    }
    notifyListeners();
  }

  /// 切台：歌词数据全部作废，**显示意图保留**
  void onChannelChanged(String channelId) {
    if (_channelId == channelId) {
      // 同一台重载（换源/重连）不动意图，只把已查结果留着继续用
      return;
    }
    _channelId = channelId;
    _gen++;
    _doc = null;
    _rawDoc = null;
    _querying = false;
    _notFound = false;
    _raw = '';
    _hasAnchor = false;
    _anchorPos = Duration.zero;
    _midJoined = false;
    _titleSeen = 0;
    notifyListeners();
  }

  /// 曲名变化（由 PlayerController 在 media-title 有效变化时调用）。
  ///
  /// [pos] 是「现在这条流播到第几秒」，只在非首曲时作为锚点。
  void onTrack(String rawTitle, Duration pos) {
    final t = rawTitle.trim();
    if (t.isEmpty || t == _raw) return;
    _raw = t;
    _titleSeen++;
    if (_titleSeen == 1) {
      // 进台第一首：唱到哪儿不知道，宁可不点亮也不瞎猜
      _midJoined = true;
      _hasAnchor = false;
      _anchorPos = Duration.zero;
    } else {
      _midJoined = false;
      _hasAnchor = true;
      _anchorPos = pos;
    }
    _doc = null;
    _rawDoc = null;
    _notFound = false;
    if (_enabled && _visible) unawaited(_ensureFetch());
    notifyListeners();
  }

  /// 歌词时间微调（毫秒，正 = 歌词整体延后、负 = 提前）。
  /// 设置在「电台歌词显示」下面调，用来补偿电台推曲名偏早/偏晚、
  /// 长前奏等情况；不放拖拽校准（会跟音量手势打架）。
  int _offsetMs = 0;
  int get offsetMs => _offsetMs;

  void setOffset(int ms) {
    if (_offsetMs == ms) return;
    _offsetMs = ms;
    notifyListeners();
  }

  /// 歌词简繁转换（0 = 原文，1 = 转简体，2 = 转繁体）。
  /// 与设置面板/扫码管理页的「歌词简繁转换」同一份数据；切换时
  /// 只对已查到的歌词重新加工，不重新发词源请求
  int _variant = 0;
  int get variant => _variant;

  void setVariant(int v) {
    final nv = v.clamp(0, 2);
    if (_variant == nv) return;
    _variant = nv;
    _applyVariant();
    notifyListeners();
  }

  /// 按 [_variant] 把原始歌词文档加工成显示文档。
  /// 词表尚未加载完时先显示原文顶着（词表随包发布，只读一次），
  /// 加载完成后自动换成转换结果
  void _applyVariant() {
    final raw = _rawDoc;
    if (raw == null || _variant == ChineseVariantConverter.modeOriginal) {
      _doc = raw;
      return;
    }
    final cv = ChineseVariantConverter.instance;
    if (cv.loaded) {
      _doc = _convertDoc(raw);
      return;
    }
    _doc = raw;
    unawaited(cv.ensureLoaded().then((_) {
      if (_rawDoc == null || _variant == ChineseVariantConverter.modeOriginal) {
        return;
      }
      _doc = _convertDoc(_rawDoc!);
      notifyListeners();
    }));
  }

  LyricsDoc _convertDoc(LyricsDoc d) {
    return LyricsDoc(
      title: d.title,
      artist: d.artist,
      lines: [
        for (final l in d.lines)
          LyricsLine(l.time, ChineseVariantConverter.instance.convert(l.text, _variant)),
      ],
      synced: d.synced,
      duration: d.duration,
    );
  }

  /// 当前该点亮第几行（-1 = 不点亮）
  int indexAt(Duration pos) {
    final d = _doc;
    if (d == null || !d.synced || !_hasAnchor) return -1;
    var elapsed = pos - _anchorPos - Duration(milliseconds: _offsetMs);
    // 直播流的位置偶尔会倒回一点（重连），夹到 0 起步，别把整页跳走
    if (elapsed.isNegative) elapsed = Duration.zero;
    final lines = d.lines;
    var idx = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].time <= elapsed) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  // ==================== 查词 ====================

  Future<void> _ensureFetch() async {
    final t = _raw;
    if (t.isEmpty) return;
    if (_cache.containsKey(t)) {
      final cached = _cache[t];
      _rawDoc = cached;
      _applyVariant();
      _notFound = cached == null;
      _querying = false;
      notifyListeners();
      return;
    }
    final gen = ++_gen;
    _querying = true;
    _notFound = false;
    notifyListeners();
    LyricsDoc? doc;
    try {
      // 并行架构下最长路径 = LRCLIB 三姿势各 4s = 12s；LrcAPI 兜底
      // 自身 5s 必出结果，总闸放到 15s 保证兜底总能被等到
      doc = await fetchLyrics(t).timeout(const Duration(seconds: 15));
    } catch (e) {
      debugPrint('[Lyrics] query failed: $e');
      doc = null;
    }
    if (gen != _gen) return; // 已经切台/切歌，结果作废
    _querying = false;
    _rawDoc = doc;
    _applyVariant();
    _notFound = doc == null;
    if (_cache.length >= _cacheLimit) _cache.clear();
    _cache[t] = doc;
    notifyListeners();
  }

  /// 曲名 → 歌词（供测试/调试直接调用）
  ///
  /// 两路**并行**：LRCLIB 主路（三个姿势）+ LrcAPI 兜底路同时出发。
  /// 旧版是串行「LRCLIB 问完才轮到 LrcAPI」，而整个链条共享 8 秒总
  /// 超时——LRCLIB 在国内访问经常慢，三个请求一卡 8 秒就烧完，直接
  /// 判「查无」，兜底根本轮不到跑。并行后 LrcAPI 先到就先算数；主路
  /// 命中时优先主路（带时间轴、质量更高）。
  static Future<LyricsDoc?> fetchLyrics(String rawTitle) async {
    final icy = parseIcyTitle(rawTitle);
    if (icy.track.isEmpty) return null;

    // 兜底路立刻出发，不等主路
    final fallback = _fetchFromLrcApi(icy);

    LyricsDoc? fromLrclib;
    try {
      // 一级：歌名 + 歌手（LRCLIB 最准的姿势）
      var rows = await _search(track: icy.track, artist: icy.artist)
          .timeout(const Duration(seconds: 4), onTimeout: () => const []);
      // 二级：只按歌名，结果里靠歌手相似度挑
      if (rows.isEmpty && icy.artist.isNotEmpty) {
        rows = await _search(track: icy.track)
            .timeout(const Duration(seconds: 4), onTimeout: () => const []);
      }
      // 三级：关键词模糊（曲名格式古怪时的兜底）
      if (rows.isEmpty) {
        rows = await _search(q: rawTitle.trim())
            .timeout(const Duration(seconds: 4), onTimeout: () => const []);
      }
      if (rows.isNotEmpty) {
        final best = _pick(rows, icy.artist);
        if (best != null) fromLrclib = _docFromLrclibRow(best, icy);
      }
    } catch (_) {
      // LRCLIB 网络层挂了：不拖累整体，还有并行在跑的 LrcAPI
      fromLrclib = null;
    }
    if (fromLrclib != null && fromLrclib.lines.isNotEmpty) return fromLrclib;
    return fallback;
  }

  /// LRCLIB 行 → 歌词文档（fetchLyrics 与调用方解耦出的纯转换）
  static LyricsDoc? _docFromLrclibRow(
      Map<String, dynamic> best, IcyTitle icy) {
    final synced = (best['syncedLyrics'] as String?)?.trim() ?? '';
    final plain = (best['plainLyrics'] as String?)?.trim() ?? '';
    final durSec = (best['duration'] as num?)?.toInt();

    if (synced.isNotEmpty) {
      final lines = parseLrc(synced);
      if (lines.isEmpty) return null;
      return LyricsDoc(
        title: (best['trackName'] as String?) ?? icy.track,
        artist: (best['artistName'] as String?) ?? icy.artist,
        lines: lines,
        duration: durSec == null ? null : Duration(seconds: durSec),
      );
    }
    // LRCLIB 有条目但没歌词（空壳/纯音乐标记）：返回 null，
    // 由 fetchLyrics 统一落到并行的 LrcAPI 兜底
    if (synced.isEmpty && plain.isEmpty) return null;
    if (plain.isNotEmpty) {
      final lines = [
        for (final l in const LineSplitter().convert(plain))
          if (l.trim().isNotEmpty) LyricsLine(Duration.zero, l.trim()),
      ];
      if (lines.isEmpty) return null;
      return LyricsDoc(
        title: (best['trackName'] as String?) ?? icy.track,
        artist: (best['artistName'] as String?) ?? icy.artist,
        lines: lines,
        synced: false,
        duration: durSec == null ? null : Duration(seconds: durSec),
      );
    }
    return null;
  }

  /// 兜底词源：LrcAPI（HisAtri/LrcApi 开源聚合项目，公共实例
  /// `api.lrc.cx`）。`GET /lyrics?title=&artist=` 直接返回 LRC 全文，
  /// 空响应/404 = 没有。返回的是整段 LRC 文本，[ar:][ti:] 头没有时间
  /// 戳，parseLrc 会自动跳过；曲名/歌手从头部捞，捞不到用 ICY 拆的。
  ///
  /// 这个源是社区项目，公共实例可能限流或下线——失败静默返回 null，
  /// 界面走「查无歌词」，不影响播放。
  static const String _lrcApiBase = 'https://api.lrc.cx/lyrics';

  /// 歌手名宽松比对：完全包含、或共享连续两字（中文）都算沾边——
  /// 「胡夏」vs「胡夏&郁可唯」通过，「S.H.E」vs「小谭同学」不通过
  static bool _artistLooselyMatches(String a, String b) {
    String norm(String v) =>
        v.toLowerCase().replaceAll(RegExp(r'[\s.·・&+/、,，+]'), '');
    final x = norm(a);
    final y = norm(b);
    if (x.isEmpty || y.isEmpty) return true;
    if (x.contains(y) || y.contains(x)) return true;
    for (var i = 0; i + 2 <= y.length; i++) {
      if (x.contains(y.substring(i, i + 2))) return true;
    }
    for (var i = 0; i + 2 <= x.length; i++) {
      if (y.contains(x.substring(i, i + 2))) return true;
    }
    return false;
  }

  /// 制作名单行：作词/作曲/编曲…开头的元信息行，纯文本歌词里整段
  /// 展示时不需要（电台场景用户只想看歌词本身）
  static final RegExp _creditLineRe = RegExp(
      r'^(作词|作詞|作曲|填詞|编曲|編曲|制作人|製作人|混音|母带|母帶|录音|錄音|'
      r'吉他|贝斯|貝斯|键盘|鼓|和声|和聲|弦乐|弦樂|监制|監製|统筹|統籌|出品|发行|'
      r'發行|OP|SP|出版|MV|和音|配唱|录音室|錄音室)[：:]');

  static Future<LyricsDoc?> _fetchFromLrcApi(IcyTitle icy) async {
    if (icy.track.isEmpty) return null;
    final params = <String, String>{'title': icy.track};
    if (icy.artist.isNotEmpty) params['artist'] = icy.artist;
    final uri = Uri.parse(_lrcApiBase).replace(queryParameters: params);
    final http.Response resp;
    try {
      resp = await http
          .get(uri, headers: {'User-Agent': _ua})
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      return null;
    }
    if (resp.statusCode != 200) {
      debugPrint('[Lyrics] LrcAPI ${resp.statusCode} for $uri');
      return null;
    }
    final body = utf8.decode(resp.bodyBytes).trim();
    if (body.isEmpty) return null;
    // 200 但返回 JSON 错误体（如 {"error":...}）：不算歌词。
    // 不能用 startsWith('[') 判断——LRC 歌词本身就以 [Verse]/[ti:] 这类
    // 方括号标签开头（v2.3.47 曾因此把整源歌词全部误杀，用户两首歌
    // 「两个词源都查不到」就是它干的），这里改为真的 JSON 解析成功才算错
    try {
      jsonDecode(body);
      return null; // 能被解析成 JSON = 错误体，不是歌词
    } on FormatException {
      // 解析失败 = 普通文本/LRC，继续
    }
    final lines = parseLrc(body);
    // 错歌防护：LrcAPI 有时只按标题匹配，返回**同名的另一首歌**
    // （实测：请求 S.H.E《怎么办》，返回小谭同学《怎么办》，词曲全对
    // 不上）。这类 LRC 首行往往是「歌名 - 歌手」形态，歌手与请求的
    // 对不上 → 视为错歌弃用，宁可查无也不放错词。
    if (lines.isNotEmpty && icy.artist.isNotEmpty) {
      final m = RegExp(r'^(.{1,40}?)\s*[-–—]\s*(.{1,30})$')
          .firstMatch(lines.first.text.trim());
      if (m != null &&
          !_artistLooselyMatches(icy.artist, m.group(2)!.trim())) {
        debugPrint('[Lyrics] LrcAPI 疑似错歌: ${lines.first.text} (要: '
            '${icy.artist} - ${icy.track})');
        return null;
      }
    }
    if (lines.isEmpty) {
      // 纯文本歌词：LrcAPI 用 `[!text]` 前缀标记无时间轴版本（如
      // 枯木逢春《我们总会在夏天相遇》）。整段展示（与 LRCLIB 纯文本
      // 同一待遇），跳过 作词/作曲 一类制作名单行。
      final text = body.replaceFirst(RegExp(r'^\[!text\]\s*'), '');
      final plain = <LyricsLine>[];
      for (final l in const LineSplitter().convert(text)) {
        final t = l.trim();
        if (t.isEmpty) continue;
        if (_creditLineRe.hasMatch(t)) continue;
        plain.add(LyricsLine(Duration.zero, t));
      }
      if (plain.isEmpty) return null;
      return LyricsDoc(
          title: icy.track, artist: icy.artist, lines: plain, synced: false);
    }
    var title = icy.track;
    var artist = icy.artist;
    for (final l in const LineSplitter().convert(body)) {
      final m = RegExp(r'^\[(ti|ar):(.*)\]\s*$').firstMatch(l.trim());
      if (m == null) continue;
      final v = m.group(2)!.trim();
      if (v.isEmpty) continue;
      if (m.group(1) == 'ti') {
        title = v;
      } else {
        artist = v;
      }
    }
    return LyricsDoc(title: title, artist: artist, lines: lines);
  }

  static Future<List<Map<String, dynamic>>> _search({
    String? track,
    String? artist,
    String? q,
  }) async {
    final params = <String, String>{};
    if (q != null && q.isNotEmpty) {
      params['q'] = q;
    } else {
      if (track != null && track.isNotEmpty) params['track_name'] = track;
      if (artist != null && artist.isNotEmpty) params['artist_name'] = artist;
    }
    if (params.isEmpty) return const [];
    final uri = Uri.parse('$_api/search').replace(queryParameters: params);
    final resp = await http.get(uri, headers: {
      'User-Agent': _ua,
      'Lrclib-Client': _ua,
    });
    if (resp.statusCode == 404) return const [];
    if (resp.statusCode != 200) {
      debugPrint('[Lyrics] LRCLIB ${resp.statusCode} for $uri');
      return const [];
    }
    final data = jsonDecode(utf8.decode(resp.bodyBytes));
    if (data is! List) return const [];
    return [
      for (final e in data)
        if (e is Map) e.cast<String, dynamic>(),
    ];
  }

  /// 挑最优：带时间轴 > 歌手匹配 > 时长有值（可做版本甄别）。
  /// 时长在这里没有对照物（直播流没有「本曲总长」），只作为质量权重。
  static Map<String, dynamic>? _pick(
      List<Map<String, dynamic>> rows, String artist) {
    Map<String, dynamic>? best;
    var bestScore = -1;
    final want = artist.toLowerCase().trim();
    for (final r in rows) {
      var score = 0;
      final a = ((r['artistName'] as String?) ?? '').toLowerCase();
      if (want.isNotEmpty) {
        if (a == want) {
          score += 4;
        } else if (a.contains(want) || want.contains(a)) {
          score += 2;
        }
      }
      final synced = (r['syncedLyrics'] as String?)?.trim() ?? '';
      final plain = (r['plainLyrics'] as String?)?.trim() ?? '';
      if (synced.isNotEmpty) {
        score += 3;
      } else if (plain.isNotEmpty) {
        score += 1;
      } else {
        continue; // 两句都没有，纯元数据条目，没用
      }
      if (r['instrumental'] == true) score -= 2; // 纯音乐，没词可唱
      if (score > bestScore) {
        bestScore = score;
        best = r;
      }
    }
    return best;
  }

  // ==================== 曲名 / LRC 解析 ====================

  /// ICY `StreamTitle` 清洗拆分：「歌手 - 歌名」是最常见的格式。
  ///
  /// 处理：去【】标签、括号里的版本标注（Live/伴奏/DJ 版）不参与查询
  /// 但也不算错误、多个分隔符都认、压缩空白。
  static IcyTitle parseIcyTitle(String raw) {
    var s = raw.trim();
    // 【xxx】前缀标签（很多台这么写）
    s = s.replaceAll(RegExp(r'【[^】]*】'), ' ');
    // 去掉括号里的版本标注：查询时不需要，反而降低命中率
    s = s.replaceAll(RegExp(r'[（(][^）)]*[）)]'), ' ');
    s = s.replaceAll(RegExp(r'\s{2,}'), ' ').trim();

    for (final sep in const [' - ', ' – ', ' — ', '-', '－', '–', '—', '|']) {
      final i = s.indexOf(sep);
      if (i <= 0) continue;
      final left = s.substring(0, i).trim();
      final right = s.substring(i + sep.length).trim();
      if (left.isEmpty || right.isEmpty) continue;
      // 左边短、右边长 → 多半是「歌手 - 歌名」
      if (left.length <= right.length + 6) {
        return IcyTitle(_tidy(right), _tidy(left));
      }
      return IcyTitle(_tidy(left), _tidy(right));
    }
    return IcyTitle(_tidy(s), '');
  }

  static String _tidy(String s) => s
      .replaceAll(RegExp(r'^[\s\-–—_|/]+'), '')
      .replaceAll(RegExp(r'[\s\-–—_|/]+$'), '')
      .trim();

  /// LRC → 带时间轴的歌词行。忽略 `[ar:]` 一类元数据标签、空行。
  static List<LyricsLine> parseLrc(String lrc) {
    final tagRe = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
    final out = <LyricsLine>[];
    for (final raw in const LineSplitter().convert(lrc)) {
      final matches = tagRe.allMatches(raw);
      if (matches.isEmpty) continue;
      final text = raw.replaceAll(tagRe, '').trim();
      if (text.isEmpty) continue;
      for (final m in matches) {
        final min = int.tryParse(m.group(1)!) ?? 0;
        final sec = int.tryParse(m.group(2)!) ?? 0;
        final fracRaw = m.group(3);
        var ms = 0;
        if (fracRaw != null) {
          // 两位=百分秒，三位=毫秒
          ms = fracRaw.length == 3
              ? (int.tryParse(fracRaw) ?? 0)
              : (int.tryParse(fracRaw.padRight(2, '0')) ?? 0) * 10;
        }
        out.add(LyricsLine(
          Duration(minutes: min, seconds: sec, milliseconds: ms),
          text,
        ));
      }
    }
    out.sort((a, b) => a.time.compareTo(b.time));
    return out;
  }
}
