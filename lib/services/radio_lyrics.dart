import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

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
    this.unverifiedName = false,
  });

  final String title;
  final String artist;
  final List<LyricsLine> lines;

  /// 是否带时间轴：纯文本歌词没有时间戳，只能整段展示、不做逐句点亮
  final bool synced;

  /// 词库里标注的标准时长（用于版本甄别，顺带能反推切歌点）
  final Duration? duration;

  /// 歌名未证实：LrcAPI 返回的歌名（[ti:] / 首行「歌名 - 歌手」）与
  /// 电台报的歌名对不上，且没有版本标注可解释。常见于电台 ICY 被
  /// 语音识别抄烂（实测 891 台报「蜃楼转移（释怀版）」，真歌是
  /// 苏星婕《爱情转移 (释怀版)》）——此时查无与放行都可能是错的，
  /// 降级处理：整个查询梯子没有「歌名可证实」的结果时才最后兜底
  final bool unverifiedName;

  bool get isEmpty => lines.isEmpty;
}

/// 任意括号/书名号段（用户规则：括号里的一般不是主歌曲名，是专辑/
/// 版本标注——剥掉后剩下的才是主名。覆盖中英文括号与书名号）。
/// 顶层定义：IcyTitle（先声明）与 RadioLyrics 都要用
final RegExp _anyParen = RegExp(r'[（(《〈\[【][^）)》〉\]】]*[）)》〉\]】]');

/// ICY 曲名拆出来的两个字段
@immutable
class IcyTitle {
  const IcyTitle(this.track, this.artist);

  final String track;
  final String artist;

  /// 主歌名（用户规则，v2.3.63 定稿）：**符号外头的才是主曲名**——
  /// 「谢幕（我喜欢）」主名是谢幕，括号里的是专辑/版本标注，不是歌名；
  /// 查询与歌名核验一律以主名为准。剥完为空（整串都在括号里的怪名）
  /// 回退原文
  String get mainTrack {
    final m = track
        .replaceAll(_anyParen, ' ')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
    return m.isEmpty ? track : m;
  }

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
    if (v) unawaited(_ensureChannelOffsetsLoaded());
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
    // 自动偏移按台存，换台后先确保已从磁盘读回（否则新台的偏移是 0）
    unawaited(_ensureChannelOffsetsLoaded());
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
    // 预读的下一首也作废（新台重新来）
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _pendingTrack = '';
    _pendingPos = Duration.zero;
    _pendingDoc = null;
    _pendingAt = null;
    _pendingGen++;
    notifyListeners();
    // 本台若有记住的偏移，把设置面板的数字同步过来（否则面板还显示
    // 上一个台调的秒数，用户再微调就调歪了）
    _reportOffset();
  }

  /// 手动重查当前曲目（v2.3.62）：电台歌不听用户的——错词不等
  /// 电台重放才能救，点一下清掉这首的缓存立刻重走查询链路。
  /// 词源的间歇性坏窗口（同 query 先吐错歌后吐对的）靠它当场自愈
  Future<void> refetch() async {
    final t = _raw;
    if (t.isEmpty) return;
    _cache.remove(t);
    await _ensureFetch();
  }

  /// 曲名变化（由 PlayerController 在 media-title 有效变化时调用）。
  ///
  /// [pos] 是「现在这条流播到第几秒」。
  ///
  /// 电台会把下一首的曲名**提前**推出来（提前量就是本台的时间偏移）。
  /// 所以新曲名到达时不立刻上台：先在后台把歌名/歌词查好备着，屏上
  /// 继续显示上一首；等偏移时间到（这首歌真正开始）再整体切换。
  /// 这样歌名和歌词都不会提前冒出来。
  void onTrack(String rawTitle, Duration pos) {
    final t = rawTitle.trim();
    if (t.isEmpty || t == _raw || t == _pendingTrack) return;
    final delay = offsetMs.clamp(0, 120000);
    // 进台第一首（台上还没有歌可留）或本台没设偏移：直接上台
    if (_raw.isEmpty || delay == 0) {
      _pendingTimer?.cancel();
      _pendingTimer = null;
      _pendingTrack = '';
      _pendingAt = null;
      _adopt(t, pos);
      return;
    }
    // 预读：歌词先拉回来备着，显示仍停在上一首
    _pendingTrack = t;
    _pendingPos = pos;
    _pendingDoc = null;
    _pendingAt = DateTime.now();
    _pendingGen++;
    _pendingTimer?.cancel();
    unawaited(_prefetchPending(t));
    _schedulePendingSwitch();
    notifyListeners();
  }

  // ---------- 预读待上台的下一首 ----------

  String _pendingTrack = '';
  Duration _pendingPos = Duration.zero;
  LyricsDoc? _pendingDoc;
  DateTime? _pendingAt;
  Timer? _pendingTimer;
  int _pendingGen = 0;

  void _schedulePendingSwitch() {
    _pendingTimer?.cancel();
    final at = _pendingAt;
    if (at == null || _pendingTrack.isEmpty) return;
    final delay = offsetMs.clamp(0, 120000);
    final remain = delay - DateTime.now().difference(at).inMilliseconds;
    if (remain <= 0) {
      _adoptPending();
      return;
    }
    _pendingTimer = Timer(Duration(milliseconds: remain), _adoptPending);
  }

  void _adoptPending() {
    final t = _pendingTrack;
    if (t.isEmpty) return;
    final pos = _pendingPos;
    final doc = _pendingDoc;
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _pendingTrack = '';
    _pendingPos = Duration.zero;
    _pendingDoc = null;
    _pendingAt = null;
    _adopt(t, pos, doc: doc);
  }

  Future<void> _prefetchPending(String t) async {
    final gen = ++_pendingGen;
    LyricsDoc? doc;
    if (_cache.containsKey(t)) {
      doc = _cache[t];
    } else {
      try {
        doc = await fetchLyrics(t).timeout(const Duration(seconds: 20));
      } catch (e) {
        debugPrint('[Lyrics] 预读失败: $e');
        doc = null;
      }
      if (gen != _pendingGen) return;
      if (_cache.length >= _cacheLimit) _cache.clear();
      // 「歌名未证实」不缓存（与 _ensureFetch 同规则）
      if (doc == null || !doc.unverifiedName) _cache[t] = doc;
    }
    if (gen != _pendingGen || _pendingTrack != t) return;
    _pendingDoc = doc;
    notifyListeners();
  }

  /// 把曲名正式上台（切标题 + 立锚点 + 换歌词）
  void _adopt(String t, Duration pos, {LyricsDoc? doc}) {
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
    _rawDoc = doc;
    _doc = null;
    _notFound = false;
    _querying = false;
    if (doc != null) {
      _applyVariant();
    } else if (_enabled && _visible) {
      unawaited(_ensureFetch());
    }
    notifyListeners();
  }

  /// 歌词时间微调（毫秒，正 = 歌词整体延后、负 = 提前）。
  /// 设置在「电台歌词显示」下面调；调过之后按台记住（见下方
  /// [setOffset]），换台回来不用重调，未校准过的台沿用最近一次的值
  int get offsetMs => _channelOffsets[_channelId] ?? _baseOffsetMs;

  void setOffset(int ms) {
    final ch = _channelId;
    final hasCh = ch != null && ch.isNotEmpty;
    final changed =
        _baseOffsetMs != ms || (hasCh && _channelOffsets[ch] != ms);
    _baseOffsetMs = ms;
    // 控制器刚把这个值写进设置，记下来——否则切台时会把「已经是这个
    // 值」误判成变化，或者该同步时漏同步
    _reportedOffset = ms;
    if (hasCh) {
      _channelOffsets[ch] = ms;
      unawaited(_saveChannelOffsets());
    }
    if (changed) {
      // 待上台的下一首按新偏移重算切换时刻（否则调完要等旧倒计时）
      if (_pendingTrack.isNotEmpty) _schedulePendingSwitch();
      notifyListeners();
    }
  }

  // ============ 按台记忆的偏移量 ============
  //
  // 电台编码器推 StreamTitle 的时机各台不一样（有的提前几秒，有的
  // 提前半分钟），同台基本稳定。因此偏移量必须**按台**记：调好一台
  // 之后换台回来还在，不用重调。
  //
  // 为什么不做「全自动」：曲名推送偏早时，上一首的曲名和下一首的曲名
  // 是**同样偏早**的，两者相减得到的时间差仍然等于这首歌的真实长度，
  // 偏早量被抵消掉——纯元数据里没有任何可观测的量能反推出它。要真
  // 自动只能靠音频波形检测歌曲间隙，当前播放链路拿不到音频电平，故
  // 采用「调一次、按台记住」的方案。

  /// 未按台校准过的台沿用的默认值（来自设置里的全局微调）
  int _baseOffsetMs = 0;

  /// 每个台各自的偏移量（毫秒，正 = 歌词延后）
  final Map<String, int> _channelOffsets = <String, int>{};

  static const String _channelOffsetPrefsKey = 'radio_lyrics_channel_offsets_v1';

  /// 加载协程（只跑一次，后来者复用同一个 Future——
  /// 用 bool 标记会有「异步读盘还没回来就写入新值」的竞态）
  Future<void>? _channelOffsetsLoader;

  /// 当前台是否已单独校准过（歌词状态条显示「本台」用）
  bool get hasChannelOffset {
    final ch = _channelId;
    return ch != null && ch.isNotEmpty && _channelOffsets.containsKey(ch);
  }

  /// 生效偏移变化回调（控制器用它把设置面板的数字同步成本台的值）
  void Function(int ms)? onOffsetChanged;

  int? _reportedOffset;

  void _reportOffset() {
    final eff = offsetMs;
    if (_reportedOffset == eff) return;
    _reportedOffset = eff;
    onOffsetChanged?.call(eff);
  }

  Future<void> _ensureChannelOffsetsLoaded() {
    final running = _channelOffsetsLoader;
    if (running != null) return running;
    final f = _loadChannelOffsets();
    _channelOffsetsLoader = f;
    return f;
  }

  Future<void> _loadChannelOffsets() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_channelOffsetPrefsKey);
      if (raw == null || raw.isEmpty) return;
      final m = jsonDecode(raw);
      if (m is! Map) return;
      var changed = false;
      m.forEach((k, v) {
        // 读盘期间可能已经调过某台（putIfAbsent 保护新值不被旧盘覆盖）
        if (k is String && v is num && !_channelOffsets.containsKey(k)) {
          _channelOffsets[k] = v.toInt();
          changed = true;
        }
      });
      if (changed) {
        notifyListeners();
        // 读盘回来发现当前台有记住的偏移：同步给设置面板
        _reportOffset();
      }
    } catch (e) {
      debugPrint('[Lyrics] 按台偏移读取失败: $e');
    }
  }

  Future<void> _saveChannelOffsets() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_channelOffsetPrefsKey, jsonEncode(_channelOffsets));
    } catch (e) {
      debugPrint('[Lyrics] 按台偏移保存失败: $e');
    }
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
      unverifiedName: d.unverifiedName,
    );
  }

  /// 时间轴此刻是否可信（UI 据此决定「跟时间轴」还是「整段提词器滚动」）。
  ///
  /// 两种情况不可信：
  /// - **中途加入**：进台第一首没锚点，不知道唱到第几秒；
  /// - **位置跑飞**：播放位置已越过歌词末行 15 秒以上（切台重连、
  ///   查词回来时歌已过半），锚点对不上。
  ///
  /// 不可信时不点亮任何行、改按纯文本那套自动滚动——用户要求：
  /// 「没法按时间轴处理，就按通用歌词随便滚，别一动不动」。
  bool axisUsable(Duration pos) {
    final d = _doc;
    if (d == null || !d.synced || d.lines.isEmpty) return false;
    if (!_hasAnchor) return false;
    var elapsed = pos - _anchorPos - Duration(milliseconds: offsetMs);
    if (elapsed.isNegative) elapsed = Duration.zero;
    return elapsed <= d.lines.last.time + const Duration(seconds: 15);
  }

  /// 当前该点亮第几行（-1 = 不点亮）
  int indexAt(Duration pos) {
    final d = _doc;
    if (d == null || !d.synced || !_hasAnchor) return -1;
    var elapsed = pos - _anchorPos - Duration(milliseconds: offsetMs);
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
      // 自身 5s 必出结果，主假设空时还有一轮重试（v2.3.60）——总闸
      // 放到 20s 保证重试总能被等到
      doc = await fetchLyrics(t).timeout(const Duration(seconds: 20));
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
    // 「歌名未证实」的结果不缓存（v2.3.61）：LrcAPI 时好时坏，这次
    // 兜底拿到的可能是按歌手模糊填补的错歌，下次切回重新查——源
    // 换个节点/时刻就有机会拿到带标签的正确词自愈。查无(null)仍缓存
    if (doc == null || !doc.unverifiedName) _cache[t] = doc;
    notifyListeners();
  }

  /// 曲名 → 歌词（供测试/调试直接调用）
  ///
  /// 两路**并行**：LRCLIB 主路（三个姿势）+ LrcAPI 兜底路同时出发。
  /// 旧版是串行「LRCLIB 问完才轮到 LrcAPI」，而整个链条共享 8 秒总
  /// 超时——LRCLIB 在国内访问经常慢，三个请求一卡 8 秒就烧完，直接
  /// 判「查无」，兜底根本轮不到跑。并行后 LrcAPI 先到就先算数；主路
  /// 命中时优先主路（带时间轴、质量更高）。
  ///
  /// 拆分假设（v2.3.55）：ICY 拆分一律按「歌手 - 歌名」解析，但个别
  /// 台是「歌名 - 歌手」反着推的——主假设三级查完仍无结果时，把歌
  /// 名/歌手**左右互换**再查一轮（[G.E.M.《句号》那次就是拆分错位
  /// 导致的同歌手错歌]）。
  static Future<LyricsDoc?> fetchLyrics(String rawTitle) async {
    final icy = parseIcyTitle(rawTitle);
    if (icy.track.isEmpty) return null;

    // 三路并行出发（v2.3.62：网易云升主源）：
    // 网易云词条自带正确歌名（铁证级核验、中文曲库最全）→ 第一位；
    // LRCLIB（稳定）、LrcAPI（兜底）为备选。谁先回来不等谁，
    // 最后按「可证实 > 未证实」+「来源优先级」统一排序
    final fromNetease = _fetchFromNetease(icy);
    final fromLrclib = _fetchFromLrclib(icy);
    final fromLrcApi = _fetchFromLrcApi(icy);
    final cands = <(LyricsDoc, int)>[];
    void add(Future<LyricsDoc?> f, int sourceRank) async {
      try {
        final d = await f;
        if (d != null && d.lines.isNotEmpty) cands.add((d, sourceRank));
      } catch (_) {
        // 单路网络层挂了不拖累整体
      }
    }

    add(fromNetease, 0);
    add(fromLrclib, 1);
    add(fromLrcApi, 2);
    try {
      await Future.wait<dynamic>([fromNetease, fromLrclib, fromLrcApi]);
    } catch (_) {
      // 单路抛错不拖累其他路的结果（add 里已各自兜过一层）
    }
    if (cands.isEmpty) return null;

    // 排序（v2.3.59 起）：歌名可证实 > 未证实，可证实里带轴 > 纯文本；
    // 平级时按来源优先级——网易云（词条自带正确歌名）压过 LRCLIB
    // 压过 LrcAPI（兜底）。网易云第一位的意义：LrcAPI 坏窗口乱填的
    // 零证据错歌，被网易云的可证实结果直接压掉
    int rank(LyricsDoc d) {
      if (!d.unverifiedName) return d.synced ? 3 : 2;
      return d.synced ? 1 : 0;
    }

    cands.sort((a, b) {
      final r = rank(b.$1) - rank(a.$1);
      return r != 0 ? r : a.$2 - b.$2;
    });
    return cands.first.$1;
  }

  /// LRCLIB 路（原 fetchLyrics 内联逻辑抽出，三路并行化）
  static Future<LyricsDoc?> _fetchFromLrclib(IcyTitle icy) async {
    for (final cand in _icyCandidates(icy)) {
      final rows = await _lrclibSearch(cand);
      if (rows.isEmpty) continue;
      final best = _pick(rows, cand);
      if (best == null) continue;
      final doc = _docFromLrclibRow(best, cand);
      if (doc != null && doc.lines.isNotEmpty) return doc;
    }
    return null;
  }

  /// 拆分假设列表：主假设（歌手 - 歌名）优先，互换假设兜底
  static List<IcyTitle> _icyCandidates(IcyTitle icy) {
    if (icy.artist.isEmpty || icy.artist == icy.track) return [icy];
    return [icy, IcyTitle(icy.artist, icy.track)];
  }

  /// ICY 前缀（歌手栏）→ 候选人名段。
  ///
  /// 电台很少老老实实只写歌手：实际见得多的是「煻(许佳慧)」
  /// 「G.E.M. 邓紫棋」「许佳慧 / 某某 / 群星」——台标、节目名、真名
  /// 用各种符号串成一坨。这里**把任何非文字字符都当分隔符**切开，
  /// 每一段都是一个候选人名，逐段去和条目歌手模糊比对，有一段对上
  /// 就认定是同一个人。
  ///
  /// 单字母/单字段直接丢（「G.E.M.」会切出 G/E/M，都是噪声）；
  /// 台名/音质词（FM、音乐台、高清…）也丢，它们不是人名。
  static List<String> _artistSegments(String raw) {
    final out = <String>[];
    for (final part in raw.split(RegExp(r'[^\u4e00-\u9fa5A-Za-z0-9]+'))) {
      final v = part.trim().toLowerCase();
      if (v.length < 2) continue;
      if (v.endsWith('版')) continue; // 现场版/伴奏版/女声版…
      if (_noiseWordRe.hasMatch(v)) continue;
      if (!out.contains(v)) out.add(v);
    }
    return out;
  }

  /// 前缀段里的「非人名」词：台名/音质/节目形态
  static final RegExp _noiseWordRe = RegExp(
    r'^(fm|am|dj|hd|hq|hifi|hi-fi|live|remix|inst|instrumental|acoustic|'
    r'cover|karaoke|demo|remaster|music|radio|'
    r'音乐台|电台|广播|之声|频道|在线|网络|直播|节目|精选|经典|流行|'
    r'怀旧|高清|超清|无损|原唱|伴奏|翻唱|纯音乐)$',
    caseSensitive: false,
  );

  /// 歌名清洗：剥掉一切特殊字符，只留中文/字母/数字（用户定的规则：
  /// 完全匹配不上就去掉括号/书名号/引号等特殊符号再匹配一次）。
  /// 查询用（二级半）与选词打分的第二层比较共用
  static String _cleanTrack(String t) =>
      t.toLowerCase().replaceAll(RegExp(r'[^\u4e00-\u9fa5A-Za-z0-9]'), '');

  /// 文本归一：剥特殊字符 + 繁简归一（OpenCC 词表未加载时原样返回，
  /// 无害）。歌词内容比对与 [ti:] 歌名核验共用
  static String _normText(String s) {
    final c = _cleanTrack(s);
    if (c.isEmpty) return c;
    return ChineseVariantConverter.instance
        .convert(c, ChineseVariantConverter.modeSimplified);
  }

  /// 歌名归一比对（清洗 + 繁简归一）：互不包含 = 对不上
  static bool _nameOff(String got, String want) {
    final g = _normText(got);
    final w = _normText(want);
    if (g.isEmpty || w.isEmpty) return false;
    return !(g.contains(w) || w.contains(g));
  }

  /// LrcAPI 响应头部的 `[ti:]` 元数据（无则 null）
  static String? _tiOf(String body) {
    for (final l in const LineSplitter().convert(body)) {
      final m = RegExp(r'^\[ti:(.*)\]\s*$').firstMatch(l.trim());
      if (m != null) {
        final v = m.group(1)!.trim();
        return v.isEmpty ? null : v;
      }
    }
    return null;
  }

  /// LrcAPI 响应带 `[ti:]` 元数据时的歌名核验（用户规则：歌名定生死）。
  /// 标签歌名与请求歌名清洗归一后互不包含 = 后端自作主张给了别的歌。
  /// v2.3.59 起不再整份弃用——**降级收货**：标记 [LyricsDoc.unverifiedName]，
  /// 整个查询梯子没有「歌名可证实」的结果时才最后兜底。一刀切丢弃的
  /// 教训：电台 ICY 报「蜃楼转移（释怀版）」，LrcAPI 正确返回的
  /// [ti:爱情转移 (释怀版)] 反而因标签≠请求名被拦，混进来的真错歌
  /// 却因为没有标签漏网
  static bool _tiMismatch(String body, String title) {
    if (_normText(title).isEmpty) return false;
    final ti = _tiOf(body);
    if (ti == null) return false;
    return _nameOff(ti, title);
  }

  /// 两份歌词正文是否同一首歌：取前 4 句归一后拼串，相等/互相包含直接
  /// 认同；分行粒度不同时按二字组重叠率 ≥ 60% 兜底。用于「同词同参
  /// 问两次」的一致性核验——LrcAPI 是聚合源，实测同 query 会随机返回
  /// 同歌手的另一首歌（任贤齐《对折》返回《好聚好散》），正文里又没有
  /// 歌名可比，只能用两次结果互证背书；对不上宁可不放
  static bool _sameLyricsDoc(LyricsDoc a, LyricsDoc b) {
    String blob(LyricsDoc d) {
      final buf = StringBuffer();
      for (final l in d.lines.take(4)) {
        buf.write(_normText(l.text));
      }
      return buf.toString();
    }

    final x = blob(a);
    final y = blob(b);
    if (x.isEmpty || y.isEmpty) return false;
    if (x == y || x.contains(y) || y.contains(x)) return true;
    if (x.length < 2 || y.length < 2) return false;
    final grams = <String>{for (var i = 0; i + 2 <= x.length; i++) x.substring(i, i + 2)};
    var hit = 0;
    var total = 0;
    for (var i = 0; i + 2 <= y.length; i++) {
      total++;
      if (grams.contains(y.substring(i, i + 2))) hit++;
    }
    return total > 0 && hit / total >= 0.6;
  }

  /// 任意括号/书名号段（用户规则：括号里的一般不是主歌曲名，是专辑/
  /// 版本标注——剥掉后剩下的才是主名。覆盖中英文括号与书名号）
  static final RegExp _anyParenRe = _anyParen;

  /// 版本标注括号：词库条目歌名常写成「逆风明媚(Live)」「某某(伴奏)」
  /// 「某某【钢琴版】」——查询与比较时剥掉（LDDC 同款做法）
  static final RegExp _versionParenRe = RegExp(
    r'[\(（\[【][^)）\]】]*'
    r'(?:live|remix|inst|instrumental|acoustic|cover|karaoke|demo|remaster|'
    r'伴奏|翻唱|现场|纯音乐|钢琴|吉他|弹唱|和声|版)'
    r'[^)）\]】]*[\)）\]】]',
    caseSensitive: false,
  );

  /// 歌名查询变体（逐级放宽，LDDC/网易系工具的通用做法）：
  /// **主名（剥全部括号，用户规则 v2.3.63：符号外才是主曲名，括号里
  /// 是专辑/标注不参与主查询）** → 原文括号形（兜「蜃楼转移（释怀版）」
  /// 这类主名本身查无、括号形后端反而能解析的）→ 剥版本括号 →
  /// 全清洗（只留文字）
  static List<String> _trackVariants(String track) {
    final out = <String>[];
    void add(String v) {
      v = v.trim();
      if (v.isNotEmpty && !out.contains(v)) out.add(v);
    }

    final main = track
        .replaceAll(_anyParenRe, ' ')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
    add(main);
    add(track);
    add(track
        .replaceAll(_versionParenRe, '')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim());
    final clean = _cleanTrack(track);
    if (clean.isNotEmpty) add(clean);
    return out;
  }

  /// 查询用歌名全变体（去重）：原文 → 剥版本括号 → 全清洗 → 各自的
  /// 繁体/简体形。用户规则：**简体查不到查繁体、繁体不到查简体，都不中
  /// 才判查无**——词库条目简繁混收（LRCLIB 港台条目全是繁体名，
  /// 酷狗/网易系全是简体），只拿请求原文一种写法查会漏
  static List<String> _titleQueryVariants(String track) {
    final base = _trackVariants(track);
    final out = List<String>.from(base);
    final cv = ChineseVariantConverter.instance;
    for (final v in base) {
      for (final mode in const [
        ChineseVariantConverter.modeTraditional,
        ChineseVariantConverter.modeSimplified,
      ]) {
        final c = cv.convert(v, mode);
        if (c != v && c.trim().isNotEmpty && !out.contains(c)) out.add(c);
      }
    }
    return out;
  }

  /// LRCLIB 三姿势：歌名+歌手 → 只按歌名 → 关键词模糊。
  /// 每个请求 4 秒超时，慢网不拖死整链
  static Future<List<Map<String, dynamic>>> _lrclibSearch(IcyTitle icy) async {
    // 一级：歌名 + 歌手（LRCLIB 最准的姿势）。歌手用前缀切出来的段
    // ——「煻(许佳慧)」整串传进去词库查不到，取「许佳慧」才命中；
    // 段按出现顺序试前两个，真名不一定排第一
    final segs = _artistSegments(icy.artist);
    final artists = segs.isEmpty ? const [''] : segs.take(2).toList();
    var rows = const <Map<String, dynamic>>[];
    for (final a in artists) {
      if (a.isEmpty) continue;
      // 主名第一（用户规则 v2.3.63）：符号外才是主曲名
      rows = await _search(track: icy.mainTrack, artist: a)
          .timeout(const Duration(seconds: 4), onTimeout: () => const []);
      if (rows.isNotEmpty) break;
    }
    // 二级：只按歌名，结果里靠歌手相似度挑
    if (rows.isEmpty && icy.artist.isNotEmpty) {
      rows = await _search(track: icy.mainTrack)
          .timeout(const Duration(seconds: 4), onTimeout: () => const []);
    }
    // 二级半：歌名逐级放宽查（业界做法，LDDC 同款）：剥版本括号 →
    // 全清洗（只留文字）→ 繁体形 → 简体形。词库条目歌名常带
    // (Live)/(伴奏)/书名号，且简繁混收——只拿原文一种写法查会漏
    if (rows.isEmpty) {
      for (final v in _titleQueryVariants(icy.track).skip(1)) {
        rows = await _search(track: v)
            .timeout(const Duration(seconds: 4), onTimeout: () => const []);
        if (rows.isNotEmpty) break;
      }
    }
    // 三级：关键词模糊（曲名格式古怪时的兜底）
    if (rows.isEmpty) {
      final q = icy.artist.isEmpty
          ? icy.track
          : '${icy.artist} - ${icy.track}';
      rows = await _search(q: q)
          .timeout(const Duration(seconds: 4), onTimeout: () => const []);
    }
    return rows;
  }

  /// LRCLIB 行 → 歌词文档（fetchLyrics 与调用方解耦出的纯转换）
  static LyricsDoc? _docFromLrclibRow(
      Map<String, dynamic> best, IcyTitle icy) {
    final synced = (best['syncedLyrics'] as String?)?.trim() ?? '';
    final plain = (best['plainLyrics'] as String?)?.trim() ?? '';
    final durSec = (best['duration'] as num?)?.toInt();
    // 歌名可证实性：条目歌名与主名（用户规则：符号外才是主曲名）
    // 归一后互不包含 → 标记「歌名未证实」，跨源汇总时让位给可证实
    // 的结果（与 LrcAPI [ti:] 同一待遇）
    final unverified = _nameOff(
        ((best['trackName'] as String?) ?? '').trim(), icy.mainTrack);

    if (synced.isNotEmpty) {
      final lines = parseLrc(synced);
      if (lines.isEmpty) return null;
      return LyricsDoc(
        title: (best['trackName'] as String?) ?? icy.track,
        artist: (best['artistName'] as String?) ?? icy.artist,
        lines: lines,
        duration: durSec == null ? null : Duration(seconds: durSec),
        unverifiedName: unverified,
      );
    }
    // LRCLIB 有条目但没歌词（空壳/纯音乐标记）：返回 null，
    // 由 fetchLyrics 统一落到并行的 LrcAPI 兜底
    if (synced.isEmpty && plain.isEmpty) return null;
    if (plain.isNotEmpty) {
      final lines = [
        for (final l in const LineSplitter().convert(plain))
          if (_stripInlineTranslation(l.trim()).isNotEmpty)
            LyricsLine(Duration.zero, _stripInlineTranslation(l.trim())),
      ];
      if (lines.isEmpty) return null;
      return LyricsDoc(
        title: (best['trackName'] as String?) ?? icy.track,
        artist: (best['artistName'] as String?) ?? icy.artist,
        lines: lines,
        synced: false,
        duration: durSec == null ? null : Duration(seconds: durSec),
        unverifiedName: unverified,
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
  /// 错歌防护用的歌手比对：两边都按符号切段，任一段对上就算同一人。
  /// 前缀段与对方歌手段互相包含、或共享连续两个字（「许佳慧」vs
  /// 「许佳慧(女)」）都放行；两边都提不出人名段时不拦（信息不足，
  /// 宁可信其有——真正的错歌由歌名分来压）
  static bool _artistLooselyMatches(String a, String b) {
    final x = _artistSegments(a);
    final y = _artistSegments(b);
    if (x.isEmpty || y.isEmpty) return true;
    for (final xs in x) {
      for (final ys in y) {
        if (xs.contains(ys) || ys.contains(xs)) return true;
        for (var i = 0; i + 2 <= ys.length; i++) {
          if (xs.contains(ys.substring(i, i + 2))) return true;
        }
      }
    }
    return false;
  }

  /// 制作名单行：作词/作曲/编曲…开头的元信息行，纯文本歌词里整段
  /// 展示时不需要（电台场景用户只想看歌词本身）
  static final RegExp _creditLineRe = RegExp(
      r'^(作词|作詞|作曲|填詞|编曲|編曲|制作人|製作人|混音|母带|母帶|录音|錄音|'
      r'吉他|贝斯|貝斯|键盘|鼓|和声|和聲|弦乐|弦樂|监制|監製|统筹|統籌|出品|发行|'
      r'發行|OP|SP|出版|MV|和音|配唱|录音室|錄音室)\s*[：:]');

  static Future<LyricsDoc?> _fetchFromLrcApi(IcyTitle icy) async {
    // 「歌名未证实」结果的最后兜底位：查询梯子上任何一级拿到**可证实**
    // （标签/条目歌名与请求名对得上）的结果立即返回；只有整条梯子全
    // 是未证实的，才用最先拿到的那份未证实结果兜底（聊胜于无）
    LyricsDoc? unv;
    // 歌名变体逐级放宽（含简繁双向——简体查不到查繁体、反之亦然，
    // 都不中才判查无）。每个变体内部按「同参两次互证」核验
    if (icy.artist.isEmpty) {
      for (final t in _titleQueryVariants(icy.track)) {
        final d = await _lrcApiVerified(t, '');
        if (d == null) continue;
        if (!d.unverifiedName) return d;
        unv ??= d;
      }
      return unv;
    }
    // 主假设：歌名 + 前缀切出的第一个人名（「煻(许佳慧)」→ 许佳慧，
    // 整串传进去查不到）；互换假设保留原串，兜「歌名 - 歌手」反写的台。
    // 实测教训（胡夏《交给时间》显示成《那些年》的词）：互换假设是
    // 「歌名当歌手、歌手当歌名」的乱炖 query，后端会按 title 关键词
    // 模糊匹配塞同歌手的热门歌，且这类响应常**无任何元数据**
    // （无 [ti:]、无 [ar:]、首行直接是歌词）——所有核验都无把柄。
    // 所以互换假设的结果**强制打「歌名未证实」**：主假设任何可证实
    // 结果都压过它；主假设空时先重试一轮（这源时好时坏是常态，
    // 实测同 query 会有连空的时刻），重试仍空才让未证实结果垫底
    final segs = _artistSegments(icy.artist);
    final artist = segs.isNotEmpty ? segs.first : icy.artist;
    LyricsDoc? markSwap(LyricsDoc? d) => d == null
        ? null
        : LyricsDoc(
            title: d.title,
            artist: d.artist,
            lines: d.lines,
            synced: d.synced,
            duration: d.duration,
            unverifiedName: true,
          );
    final first = await Future.wait([
      _lrcApiVerified(icy.mainTrack, artist),
      _lrcApiOnce(icy.artist, icy.mainTrack),
    ]);
    var m = first[0];
    final s = markSwap(first[1]);
    if (m == null) {
      m = await _lrcApiVerified(icy.mainTrack, artist);
    }
    final ok = [
      for (final d in [m, s])
        if (d != null && !d.unverifiedName) d
    ];
    if (ok.isNotEmpty) {
      // 两假设都命中且是同一首歌：带时间轴的优先（用户规则）
      for (final d in ok) {
        if (d.synced) return d;
      }
      return ok.first;
    }
    for (final d in [m, s]) {
      if (d != null && d.unverifiedName) {
        unv ??= d;
        break;
      }
    }
    for (final t in _titleQueryVariants(icy.track).skip(1)) {
      final d = await _lrcApiVerified(t, artist);
      if (d == null) continue;
      if (!d.unverifiedName) return d;
      unv ??= d;
    }
    return unv;
  }

  /// 同词同参并行问两次，互证后才收货。LrcAPI 聚合后端实测不稳定：
  /// 同一 query 有时返回正确的歌、有时返回同歌手的另一首（无 [ti:]
  /// 标签时正文里没有歌名可比，无法按歌名直接判错）——两次一致才算
  /// 可信；只有一次有结果时只能放行（无法证伪），两次对不上整份弃用
  static Future<LyricsDoc?> _lrcApiVerified(String title, String artist) async {
    final r = await Future.wait([
      _lrcApiOnce(title, artist),
      _lrcApiOnce(title, artist),
    ]);
    final a = r[0];
    final b = r[1];
    if (a != null && b != null) {
      if (_sameLyricsDoc(a, b)) {
        // 同一首歌两份都可用：带时间轴的优先（用户规则）
        if (!a.synced && b.synced) return b;
        return a;
      }
      debugPrint('[Lyrics] LrcAPI 两次结果不一致, 弃用 (要: '
          '$artist - $title) A首句: ${a.lines.first.text} '
          'B首句: ${b.lines.first.text}');
      return null;
    }
    return a ?? b;
  }

  static Future<LyricsDoc?> _lrcApiOnce(String title, String artist) async {
    if (title.isEmpty) return null;
    final params = <String, String>{'title': title};
    if (artist.isNotEmpty) params['artist'] = artist;
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
    // 首行「歌名 - 歌手」自报家门提取（词库条目常见形态）
    String? firstTitle;
    String? firstArtist;
    if (lines.isNotEmpty) {
      final m = RegExp(r'^(.{1,40}?)\s*[-–—]\s*(.{1,30})$')
          .firstMatch(lines.first.text.trim());
      if (m != null) {
        firstTitle = m.group(1)!.trim();
        firstArtist = m.group(2)!.trim();
      }
    }
    // 错歌防护：LrcAPI 有时只按标题匹配，返回**同名的另一首歌**
    // （实测：请求 S.H.E《怎么办》，返回小谭同学《怎么办》，词曲全对
    // 不上）。首行自报家门的歌手与请求的对不上 → 视为错歌弃用
    if (lines.isNotEmpty &&
        artist.isNotEmpty &&
        firstArtist != null &&
        !_artistLooselyMatches(artist, firstArtist)) {
      debugPrint('[Lyrics] LrcAPI 疑似错歌: ${lines.first.text} (要: '
          '$artist - $title)');
      return null;
    }
    // 歌名可证实性判定（v2.3.61 定稿）：带 [ti:] 且与请求名对得上、
    // 或首行自报家门的歌名与请求名对得上 = 可证实；**零证据
    // （无 [ti:] 且首行不是「歌名-歌手」形态）一律降级**。实测教训
    // （891台「白小白 - 人生漫漫」放成他另一首歌的词）：后端查无时
    // 按歌手模糊填补热门歌，响应常无任何元数据且两次互证也稳定错，
    // 零证据不能再默认当「可证实」。有 [ti:] 但对不上也降级收货
    // （蜃楼转移教训：正确答案常带着≠请求名的标签）
    final hasTi = _tiOf(body) != null;
    final selfNamed = firstTitle != null && !_nameOff(firstTitle, title);
    final unverified = _tiMismatch(body, title) || (!hasTi && !selfNamed);
    if (_tiMismatch(body, title)) {
      debugPrint('[Lyrics] LrcAPI [ti:] 与请求歌名不符, 降级收货 (要: $title)');
    } else if (!hasTi && !selfNamed) {
      debugPrint('[Lyrics] LrcAPI 响应无歌名证据, 降级收货 (要: '
          '$artist - $title)');
    }
    if (lines.isEmpty) {
      // 纯文本歌词：LrcAPI 用 `[!text]` 前缀标记无时间轴版本（如
      // 枯木逢春《我们总会在夏天相遇》）。整段展示（与 LRCLIB 纯文本
      // 同一待遇），跳过 作词/作曲 一类制作名单行。
      final text = body.replaceFirst(RegExp(r'^\[!text\]\s*'), '');
      final plain = <LyricsLine>[];
      for (final l in const LineSplitter().convert(text)) {
        final t = _stripInlineTranslation(l.trim());
        if (t.isEmpty) continue;
        if (_creditLineRe.hasMatch(t)) continue;
        plain.add(LyricsLine(Duration.zero, t));
      }
      if (plain.isEmpty) return null;
      return LyricsDoc(
          title: title,
          artist: artist,
          lines: plain,
          synced: false,
          unverifiedName: unverified);
    }
    var docTitle = title;
    var docArtist = artist;
    for (final l in const LineSplitter().convert(body)) {
      final m = RegExp(r'^\[(ti|ar):(.*)\]\s*$').firstMatch(l.trim());
      if (m == null) continue;
      final v = m.group(2)!.trim();
      if (v.isEmpty) continue;
      if (m.group(1) == 'ti') {
        docTitle = v;
      } else {
        docArtist = v;
      }
    }
    return LyricsDoc(
        title: docTitle,
        artist: docArtist,
        lines: lines,
        unverifiedName: unverified);
  }

  // ==================== 网易云词源（v2.3.62） ====================

  /// 第三词源：网易云非官方接口。与 LrcAPI 完全独立的曲库（中文覆盖
  /// 最好），实测「王菲 - 你在终点等我」LrcAPI 全线查无/乱填时，
  /// 网易云一次命中本尊。**词条自带正确歌名**——按 id 取词，搜索
  /// 条目的 trackName 就是歌名铁证，[unverifiedName] 核验直接可信：
  /// LrcAPI 坏窗口（同 query 吐错歌/按歌手乱填补）的零证据结果在
  /// 「可证实优先」排序下永远让位给它。接口非官方：失败静默返回
  /// null，另两路兜着
  static const String _ncmSearchBase = 'https://music.163.com/api/search/get';
  static const String _ncmLyricBase = 'https://music.163.com/api/song/lyric';

  static Map<String, String> get _ncmHeaders => {
        'Referer': 'https://music.163.com',
        'Cookie': 'appver=2.9.7',
        'User-Agent': _ua,
      };

  static Future<LyricsDoc?> _fetchFromNetease(IcyTitle icy) async {
    if (icy.track.isEmpty) return null;
    final segs = _artistSegments(icy.artist);
    final artist = segs.isNotEmpty ? segs.first : icy.artist;
    // 查询变体（用户规则 v2.3.63）：**主名第一**——「谢幕（我喜欢）」
    // 主名是谢幕，括号里是专辑标注，整串拿去搜会把别的《我喜欢》混进来；
    // 主名查无再用原文括号形兜底。每个变体先「歌手 歌名」再只按歌名
    final main = icy.mainTrack;
    final queries = <(String, String)>[
      for (final t in <String>[main, if (main != icy.track) icy.track]) ...[
        if (artist.isNotEmpty && artist != t) (t, '$artist $t'),
        (t, t),
      ],
    ];
    for (final (want, q) in queries) {
      Map? best;
      try {
        final uri = Uri.parse(_ncmSearchBase).replace(queryParameters: {
          's': q,
          'type': '1',
          'limit': '5',
        });
        final resp = await http
            .get(uri, headers: _ncmHeaders)
            .timeout(const Duration(seconds: 4));
        if (resp.statusCode != 200) continue;
        final data = jsonDecode(utf8.decode(resp.bodyBytes));
        final songs = (data['result']?['songs'] as List?) ?? const [];
        // 歌名定生死（_pick 同款权重）：归一相等 +5 / 互相包含 +3 /
        // 不沾 -2；歌手沾边 +2。基准 = 本级查询用的主名变体，
        // 最高分为负 = 搜出来的歌名全不沾，宁缺毋滥（错词比查无伤人）
        final wantClean = _normText(want);
        if (wantClean.isEmpty) continue;
        var bestScore = 0;
        for (final e in songs) {
          if (e is! Map) continue;
          final name = (e['name'] as String?) ?? '';
          var score = 0;
          final gotClean = _normText(name);
          if (gotClean == wantClean) {
            score += 5;
          } else if (gotClean.contains(wantClean) ||
              wantClean.contains(gotClean)) {
            score += 3;
          } else {
            score -= 2;
          }
          if (artist.isNotEmpty) {
            final ar = [
              for (final a in (e['artists'] as List? ?? const []))
                if (a is Map) (a['name'] as String?) ?? ''
            ].join(' ');
            if (_artistLooselyMatches(artist, ar)) score += 2;
          }
          if (score > bestScore) {
            bestScore = score;
            best = e;
          }
        }
      } catch (_) {
        continue; // 网络层挂了不拖累另两路
      }
      if (best == null) continue;
      final id = best['id'];
      final name = (best['name'] as String?) ?? icy.track;
      try {
        final lresp = await http
            .get(
              Uri.parse('$_ncmLyricBase?id=$id&lv=1&kv=1&tv=-1'),
              headers: _ncmHeaders,
            )
            .timeout(const Duration(seconds: 4));
        if (lresp.statusCode != 200) continue;
        final ld = jsonDecode(utf8.decode(lresp.bodyBytes));
        final lrc = (ld['lrc']?['lyric'] as String?)?.trim() ?? '';
        if (lrc.isEmpty) continue;
        final lines = parseLrc(lrc);
        if (lines.isEmpty) continue;
        final durMs = best['duration'];
        final unverified = _nameOff(name, want);
        if (unverified) {
          debugPrint('[Lyrics] 网易云条目歌名与请求不符, 降级收货 '
              '(要: ${icy.artist} - ${icy.track}, 得: $name)');
        }
        return LyricsDoc(
          title: name,
          artist: [
            for (final a in (best['artists'] as List? ?? const []))
              if (a is Map) (a['name'] as String?) ?? ''
          ].where((s) => s.isNotEmpty).join('/'),
          lines: lines,
          duration: durMs is num
              ? Duration(milliseconds: durMs.toInt())
              : null,
          unverifiedName: unverified,
        );
      } catch (_) {
        continue;
      }
    }
    return null;
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

  /// 挑最优：**歌名匹配 > 带时间轴 > 歌手匹配 > 时长有值**。
  ///
  /// 歌名匹配是 v2.3.55 加的第一道闸（G.E.M.《句号》显示成《泡沫》
  /// 的教训）：按歌手搜出来一串同歌手的歌时，歌手分大家都一样高，
  /// 谁排前面就选谁——必须先按歌名筛，对不上直接强压制。
  static Map<String, dynamic>? _pick(
      List<Map<String, dynamic>> rows, IcyTitle icy) {
    String syncedOf(Map<String, dynamic> r) =>
        (r['syncedLyrics'] as String?)?.trim() ?? '';
    String plainOf(Map<String, dynamic> r) =>
        (r['plainLyrics'] as String?)?.trim() ?? '';

    // 歌名先定生死：搜索结果只有一条有效条目（有词的）就是它，不再比
    // 歌手——名先确认，歌手只用于「多条同名/近似」时的甄别。“逆风
    // 明媚”就是这种：歌手栏被台标污染，但歌名唯一，直接认
    final usable = [
      for (final r in rows)
        if (syncedOf(r).isNotEmpty || plainOf(r).isNotEmpty) r
    ];
    if (usable.length == 1) return usable.first;

    Map<String, dynamic>? best;
    var bestScore = -1;
    // 歌手前缀切段（「煻(许佳慧)」→ 许佳慧），逐段比对
    final wants = _artistSegments(icy.artist);
    // 歌名打分基准 = 主名（用户规则 v2.3.63：符号外才是主曲名，括号里
    // 是专辑/标注）——否则「谢幕（我喜欢）」的清洗形「谢幕我喜欢」会把
    // 别的歌《我喜欢》当「互相包含」放行
    final wantTrack = icy.mainTrack.toLowerCase().trim();
    for (final r in rows) {
      var score = 0;
      // 歌手匹配：条目歌手名也切段，双向包含比，任一段命中即算。
      // 相等 +4、包含 +2（取最高，别叠加）
      final a = (r['artistName'] as String?) ?? '';
      if (wants.isNotEmpty) {
        final aSegs = _artistSegments(a);
        final pool = aSegs.isEmpty ? [a.toLowerCase().trim()] : aSegs;
        var aScore = 0;
        for (final w in wants) {
          for (final s in pool) {
            if (s.isEmpty) continue;
            if (s == w) {
              aScore = 4;
              break;
            }
            if (aScore < 2 && (s.contains(w) || w.contains(s))) aScore = 2;
          }
          if (aScore == 4) break;
        }
        score += aScore;
      }
      // 歌名匹配（同歌手不同歌防护），层层放宽（业界做法）：
      // ① 原文精确相等 +5；② 剥特殊字符后相等 +4（含繁简归一——
      // 港台条目是繁体名，用 OpenCC 都转简体再比；词表未加载时
      // convert 原样返回，无害）；③ 互相包含 +3；完全不沾 -2
      final tRaw = ((r['trackName'] as String?) ?? '').toLowerCase().trim();
      final t = ChineseVariantConverter.instance
          .convert(_cleanTrack(tRaw), ChineseVariantConverter.modeSimplified);
      final wantClean = ChineseVariantConverter.instance
          .convert(_cleanTrack(wantTrack), ChineseVariantConverter.modeSimplified);
      if (wantTrack.isNotEmpty) {
        if (tRaw == wantTrack) {
          score += 5;
        } else if (wantClean.isNotEmpty && t == wantClean) {
          score += 4;
        } else if (wantClean.isNotEmpty &&
            (t.contains(wantClean) || wantClean.contains(t))) {
          score += 3;
        } else {
          score -= 2;
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
  /// 处理：去【】标签、**括号原样保留**（v2.3.59 用户定稿：不是把
  /// 括号换成空格，也不能连内容截掉——括号形原样发给词源后端，
  /// 后端反而能解析：「蜃楼转移（释怀版）」发给 LrcAPI 能正确命中
  /// 苏星婕《爱情转移 (释怀版)》，而转成空格的「蜃楼转移 释怀版」
  /// 四不像反而查不到）、多个分隔符都认、压缩空白。
  ///
  /// 拆分一律按「左 = 歌手、右 = 歌名」处理（v2.3.55 定稿）。旧版有
  /// 个「左边短右边长才算歌手-歌名」的长度启发式，在**歌手名比歌名
  /// 长得多**时会判反（实测 G.E.M.《句号》：「G.E.M. 邓紫棋 - 句号」
  /// 9 字 > 2+6 → 歌名当成了歌手、歌手当成了歌名，查不到本尊，
  /// 按歌手乱挑选中了《泡沫》——同歌手错歌）。判断反了不要紧：
  /// [fetchLyrics] 里还有第二个假设（左右互换）兜着。
  static IcyTitle parseIcyTitle(String raw) {
    var s = raw.trim();
    // 【xxx】前缀标签（很多台这么写）
    s = s.replaceAll(RegExp(r'【[^】]*】'), ' ');
    // 括号段先用占位符保护起来再找分隔符——括号里偶尔也带「-」，
    // 直接找会把「爱情转移 (版-B)」这类切碎。切完左右两侧各自还原
    // 成原括号形：歌手侧交给 _artistSegments 按非文字切段（括号
    // 天然当分隔符，真名在括号里也切得出来，注释旧规则保留）
    const ph = '\uE000';
    final parens = <String>[];
    s = s.replaceAllMapped(RegExp(r'[（(][^）)]*[）)]'), (m) {
      parens.add(m.group(0)!);
      return ph;
    });
    s = s.replaceAll(RegExp(r'\s{2,}'), ' ').trim();

    String restore(String x) {
      for (final p in parens) {
        x = x.replaceFirst(ph, p);
      }
      return x;
    }

    for (final sep in const [' - ', ' – ', ' — ', '-', '－', '–', '—', '|']) {
      final i = s.indexOf(sep);
      if (i <= 0) continue;
      final left = s.substring(0, i).trim();
      final right = s.substring(i + sep.length).trim();
      if (left.isEmpty || right.isEmpty) continue;
      // feat 剥离（业界做法）：「晴天 (feat. 王力宏)」里 feat 后面的
      // 人是合作者不是歌名的一部分——归入歌手栏，切段后参与比对
      var track = _tidy(restore(right));
      var artist = _tidy(restore(left));
      final fm = RegExp(
              r'[\s]*[\(（\[【]?\s*(?:feat\.?|ft\.?|featuring)\s*[:：]?\s*'
              r'([^)）\]】]+)[\)）\]】]?\s*$',
              caseSensitive: false)
          .firstMatch(track);
      if (fm != null) {
        final featName = fm.group(1)!.trim();
        track = _tidy(track.substring(0, fm.start));
        if (featName.isNotEmpty) artist = _tidy('$artist $featName');
      }
      return IcyTitle(track, artist);
    }
    // 无分隔符整串（「蜃楼转移（释怀版）」）也保留括号原形
    return IcyTitle(_tidy(restore(s)), '');
  }

  static String _tidy(String s) => s
      .replaceAll(RegExp(r'^[\s\-–—_|/]+'), '')
      .replaceAll(RegExp(r'[\s\-–—_|/]+$'), '')
      .trim();

  /// 双语对照行剥离：LRCLIB 部分条目行内用 tab 挂英文翻译
  /// （实测《香水有毒》：「我曾經愛過這樣一個男人^I once loved
  /// such a man」）。歌词块一句一行大字，混着英文没法看——
  /// 只保留 tab 前的正文；正常 LRC 行内不会出现 tab，无副作用
  static String _stripInlineTranslation(String t) {
    final i = t.indexOf('\t');
    return i > 0 ? t.substring(0, i).trim() : t;
  }

  /// LRC → 带时间轴的歌词行。忽略 `[ar:]` 一类元数据标签、空行。
  static List<LyricsLine> parseLrc(String lrc) {
    final tagRe = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
    final out = <LyricsLine>[];
    for (final raw in const LineSplitter().convert(lrc)) {
      final matches = tagRe.allMatches(raw);
      if (matches.isEmpty) continue;
      var text = raw.replaceAll(tagRe, '').trim();
      if (text.isEmpty) continue;
      text = _stripInlineTranslation(text);
      // 制作名单行：LrcAPI 的词源自酷狗/网易，开头常挂「作词 : 月落」
      // 「作曲 : xxx」一串，带时间轴时会被当成正常歌词行显示——
      // 实测《逆风明媚》前 10 行全是这个，正片从 0:28 才开始
      if (_creditLineRe.hasMatch(text)) continue;
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
