import 'dart:async';

import 'package:flutter/material.dart';

import '../services/chinese_variant.dart';
import '../services/player_controller.dart';
import '../services/radio_lyrics.dart';

/// 电台歌词块（待办 L · 分栏版式定稿）。
///
/// 右侧一块圆角面板，与左侧的中央信息卡并排——左"台"右"词"，互不遮挡。
/// 面板尺寸由 [video_player_widget] 的分栏布局（`_lyricsSplit`）给定，
/// 窄屏随整版等比缩小。
///
/// **纯显示**（用户 2026-11-18 定稿）：不响应拖动、不给微调按钮——
/// 播放页左侧上滑调亮度、右侧上滑调音量，歌词块正占着右半边，任何
/// 拖动都会跟音量手势打架。时间对不准走设置里的「歌词时间微调」。
///
/// 对齐：用 [RadioLyrics.indexAt] 把「播放位置 − 曲名变化时刻 + 微调偏移」
/// 映射到 LRC 时间轴。进台第一首没有锚点（不知道唱到哪儿），此时只展示
/// 不点亮，面板内给一行说明；下一首起自动精确同步。
class RadioLyricsStage extends StatefulWidget {
  const RadioLyricsStage({super.key, required this.controller});

  final PlayerController controller;

  @override
  State<RadioLyricsStage> createState() => _RadioLyricsStageState();
}

class _RadioLyricsStageState extends State<RadioLyricsStage> {
  static const double _lineHeight = 48;

  final ScrollController _scroll = ScrollController();
  Timer? _tick;
  int _index = -1;

  // ---- 纯文本歌词（无时间轴）的自动滚动 ----
  /// 上次用户手动滚动的时刻：4 秒内自动滚动让路，不打架
  DateTime? _lastUserScroll;
  /// 到尾后停留片刻再回顶（像读一篇文章，翻到底停一停）
  int _endHoldMs = 0;

  // ---- 状态条上的「异常提示」闪现（用户 2026-11-20 五次定稿）----
  /// 当前闪着的异常提示（中途加入/位置未知/无时间轴/歌名未证实）。
  /// 只闪 4 秒就淡出，那一行交还给常驻状态（自动/简体/繁体 · 时间偏移）
  String? _tipText;
  DateTime? _tipUntil;
  /// 上一次的提示签名：变了才重新计时（切歌、中途加入状态变化）
  String _tipSig = '';

  @override
  void initState() {
    super.initState();
    // 300ms 一刷：歌词行跨度为秒级，这个频率既跟得上又不费电
    _tick = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (!mounted) return;
      final lyrics = RadioLyrics.instance;
      // 时间轴不可信（中途加入/位置跑飞）：不点亮，交给提词器滚动
      final i = lyrics.axisUsable(widget.controller.position)
          ? lyrics.indexAt(widget.controller.position)
          : -1;
      if (i != _index) {
        setState(() => _index = i);
        _scrollTo(i);
      }
      _autoScrollPlain();
      _syncStatusTip(lyrics);
    });
  }

  /// 异常提示的 4 秒闪现（用户定稿）：提示只作「刚进这首歌时告知一句」，
  /// 看完就该退场——常驻位置留给 自动/简体/繁体 · 时间偏移，那才是
  /// 需要长期瞄一眼的状态。提示文本变了（切歌/中途加入转正常）就重
  /// 新计时；提示清空则立刻交还常驻行
  void _syncStatusTip(RadioLyrics lyrics) {
    final doc = lyrics.doc;
    if (doc == null) return;
    final axisOk = doc.synced && lyrics.axisUsable(widget.controller.position);
    final tips = <String>[
      if (doc.unverifiedName) '歌名未证实 · 仅供参考',
      if (lyrics.midJoined) '中途加入 · 自动滚动',
      if (!lyrics.midJoined && !axisOk && doc.synced) '位置未知 · 自动滚动',
      if (!doc.synced) '无时间轴 · 整段展示',
    ];
    final sig = tips.join('|');
    final now = DateTime.now();
    if (sig != _tipSig) {
      _tipSig = sig;
      setState(() {
        _tipText = tips.isEmpty ? null : tips.join('   ·   ');
        _tipUntil = tips.isEmpty ? null : now.add(const Duration(seconds: 4));
      });
      return;
    }
    if (_tipText != null && _tipUntil != null && now.isAfter(_tipUntil!)) {
      setState(() {
        _tipText = null;
        _tipUntil = null;
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollTo(int i) {
    if (i < 0 || !_scroll.hasClients) return;
    final viewport = _scroll.position.viewportDimension;
    final target = (i * _lineHeight - viewport / 2 + _lineHeight / 2)
        .clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
    );
  }

  /// 纯文本歌词（没有时间轴、无从点亮）自动慢慢往下走，像提词器。
  /// 一屏装不下一整首，用户（尤其手机上不能拖）靠它看全全文。
  /// 用户刚手动滚过（桌面鼠标拖）就先让路 4 秒；滚到底停 3 秒回顶循环。
  /// 带时间轴但**锚点不可信**（中途加入 / 位置跑飞）也走这套——
  /// 用户定的规则：没法对时间轴就按通用歌词滚，别一动不动。
  void _autoScrollPlain() {
    final lyrics = RadioLyrics.instance;
    final doc = lyrics.doc;
    if (doc == null) return;
    if (doc.synced && lyrics.axisUsable(widget.controller.position)) return;
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final max = pos.maxScrollExtent;
    if (max <= 0) return; // 一屏装得下，不用滚
    // 用户 4 秒内滚过：不打架
    if (_lastUserScroll != null &&
        DateTime.now().difference(_lastUserScroll!) <
            const Duration(seconds: 4)) {
      return;
    }
    if (pos.pixels >= max - 0.5) {
      // 到底：停 3 秒回顶
      _endHoldMs += 300;
      if (_endHoldMs >= 3000) {
        _endHoldMs = 0;
        _scroll.jumpTo(0);
      }
      return;
    }
    // 20px/秒：一行 48px 约 2.4 秒，阅读节奏
    _scroll.jumpTo((pos.pixels + 6).clamp(0.0, max));
  }

  @override
  Widget build(BuildContext context) {
    final lyrics = RadioLyrics.instance;
    return AnimatedBuilder(
      animation: lyrics,
      builder: (context, _) {
        Widget body;
        if (lyrics.doc == null && !lyrics.querying && !lyrics.notFound) {
          // 开关刚打开、首帧还没拿到曲名：轻提示，不闪空白
          body = const _Hint(
            icon: Icons.hourglass_empty,
            title: '等待曲目信息…',
            subtitle: '电台推来歌名后会自动查询歌词',
          );
        } else if (lyrics.querying) {
          body = Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white54),
              ),
              const SizedBox(height: 14),
              Text(
                '正在查找歌词…',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.66),
                    fontSize: 14),
              ),
              if (lyrics.currentTrack.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    lyrics.currentTrack,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                        fontSize: 12.5),
                  ),
                ),
            ],
          );
        } else if (lyrics.notFound || lyrics.doc == null) {
          body = _Hint(
            icon: Icons.music_off,
            title: '查无歌词',
            subtitle: lyrics.currentTrack.isEmpty
                ? '当前没有可用的曲目信息'
                : '${lyrics.currentTrack}\n换个台或等下一首再试',
          );
        } else {
          final doc = lyrics.doc!;
          // 时间轴此刻能不能用：中途加入（进台第一首不知道唱到哪）、
          // 位置跑飞（越过末行）时不能用，走整段提词器滚动
          final axisOk =
              doc.synced && lyrics.axisUsable(widget.controller.position);
          // 状态条（用户 2026-11-20 五次定稿，最终版）：
          // **一行写全**所有状态——「自动/简体/繁体 · 时间偏移 -4 秒」，
          // 不做左右分置（中间会空出大半个框）、不做来回交替（要等，
          // 还会闪）。异常提示（中途加入/位置未知/无时间轴/歌名未证实）
          // 只在刚进这首歌时**顶替这一行 4 秒**，随后 fade 回常驻状态。
          // 视觉用大众最熟的「标签」形态：圆角 8（不用 20，避免跟外层
          // 歌词框的大圆角叠成双弧）、底色白 5%、边框白 12%——有块感
          // 但不抢戏，一眼就知道「这是状态，不是歌词」
          final statusText = _tipText ??
              [
                _variantChipText(lyrics.variant),
                if (lyrics.offsetMs != 0 && axisOk)
                  '时间偏移 ${_fmtOffsetSec(lyrics.offsetMs)}'
                      '${lyrics.hasChannelOffset ? '（本台已记住）' : ''}',
              ].join('   ·   ');
          body = Column(
            children: [
              // 距框左边 20px（Container 已有 14，这里补 6）；
              // 与歌词隔 10px——不贴字，也不白占一行
              Padding(
                padding: const EdgeInsets.only(left: 6, bottom: 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 420),
                    // 切换时两张叠放：高度不跳、起点不动，只有淡入淡出
                    layoutBuilder: (current, previous) => Stack(
                      alignment: Alignment.centerLeft,
                      children: [...previous, if (current != null) current],
                    ),
                    child: _StatusChip(
                      key: ValueKey(statusText),
                      text: statusText,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: ScrollConfiguration(
                  // 关掉滚动时冒出来的滑条（用户要求：一定不显示）
                  behavior: ScrollConfiguration.of(context)
                      .copyWith(scrollbars: false),
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (n is ScrollUpdateNotification &&
                          n.dragDetails != null) {
                        _lastUserScroll = DateTime.now();
                      }
                      return false;
                    },
                    child: ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.only(top: 4, bottom: 8),
                      itemCount: doc.lines.length,
                      itemExtent: _lineHeight,
                      // 带时间轴且位置可信：纯显示，禁止拖动（拖动会跟
                      // 右侧音量手势打架），自动跟随走 animateTo 不受影响。
                      // 无时间轴/位置不可信：桌面放开拖动/滚轮——用户要
                      // 看全一整首；手机仍锁（右半边是音量手势区），
                      // 靠上面的自动滚动浏览全文
                      physics: axisOk
                          ? const NeverScrollableScrollPhysics()
                          : (widget.controller.isDesktop
                              ? const ClampingScrollPhysics()
                              : const NeverScrollableScrollPhysics()),
                      itemBuilder: (context, i) {
                        final line = doc.lines[i];
                        final active = axisOk && i == _index;
                        final near = _index >= 0 && (i - _index).abs() <= 1;
                        // 整段展示（无时间轴 / 时间轴不可信）整首都要能读：
                        // 用亮的常规样式，不走「上下句淡化」那套
                        final plain = !axisOk;
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Text(
                              line.text,
                              maxLines: 2,
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: active
                                    ? Colors.white
                                    : Colors.white.withValues(
                                        alpha: plain
                                            ? 0.85
                                            : near
                                                ? 0.55
                                                : 0.26),
                                fontSize: active ? 19 : (plain ? 16.5 : 15),
                                height: 1.35,
                                fontWeight: active
                                    ? FontWeight.w700
                                    : (plain
                                        ? FontWeight.w500
                                        : FontWeight.w400),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
          );
        }
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            // 半透明浮块：让"这是一块歌词"看得见，又不抢左侧信息卡的戏
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
          ),
          child: body,
        );
      },
    );
  }
}

/// 状态条：一枚圆角矩形小标签（用户 2026-11-20 定稿形态）。
///
/// 为什么用「标签」而不是纯文字/竖线/眉线：chip 是移动端最普适的
/// 形态（微信/淘宝/视频站的标签都长这样），用户零学习成本就知道
/// 「这是一条状态，不是歌词内容」。底色与边框都压到极淡（5% / 12%），
/// 圆角只给 8——外层歌词框是 20 的大圆角，这里再用大圆角会叠成双弧，
/// 视觉上「框里套个胶囊」，显挤。
class _StatusChip extends StatelessWidget {
  const _StatusChip({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.58),
          fontSize: 11.5,
          height: 1.2,
        ),
      ),
    );
  }
}

/// 简繁档位文本（用户 2026-11-20 定稿：三档就叫 自动 / 简体 / 繁体，
/// 不用「已转简体」这类长说法——状态条要短才放得下一行写全）。
/// 词表没就绪时如实加注，别让用户以为开关坏了或没保存
String _variantChipText(int v) {
  if (v == 0) return '自动';
  final cv = ChineseVariantConverter.instance;
  final name = v == 1 ? '简体' : '繁体';
  return cv.loaded ? name : '$name（词表未就绪）';
}

String _fmtOffsetSec(int ms) {
  final sec = (ms.abs() / 1000).toStringAsFixed(ms % 1000 == 0 ? 0 : 1);
  return '${ms > 0 ? '+' : '-'}$sec 秒';
}

class _Hint extends StatelessWidget {
  const _Hint({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 36, color: Colors.white.withValues(alpha: 0.28)),
          const SizedBox(height: 14),
          Text(
            title,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.8),
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4),
                fontSize: 12.5,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
