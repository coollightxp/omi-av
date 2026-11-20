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
    });
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
          // 提示排版（用户 2026-11-20 二次定稿，重排美化）：
          // ① 状态行：左=简繁档位、右=时间偏差，两个小 chip 左右分置；
          // ② 说明行：其余提示（歌名未证实/中途加入/位置未知/无时间轴）
          //    合并成一句居中小字、单行省略——**不再逐条堆 chip**，
          //    长句叠在一起很难看（实测「已中途加入…」那条就叠了）；
          // ③ 歌词区从提示下方开始，实占不重叠（v2.3.64 浮层方案会
          //    盖住第一行歌词，已废弃）。刷新按钮删除（点了没反应）
          final tips = <String>[
            if (doc.unverifiedName) '歌名未证实 · 仅供参考',
            if (lyrics.midJoined) '中途加入 · 自动滚动',
            if (!lyrics.midJoined && !axisOk && doc.synced)
              '位置未知 · 自动滚动',
            if (!doc.synced) '无时间轴 · 整段展示',
          ];
          final showVariant = lyrics.variant != 0;
          final showOffset = lyrics.offsetMs != 0 && axisOk;
          body = Column(
            children: [
              // **单行极简状态条**（用户 2026-11-20 三次定稿：既好看
              // 又让歌词显示更多）——三行 chip 太占地，浮层又盖歌词。
              // 折中：全部提示压成一行淡色小字，左=简繁档位、中=其余
              // 提示（单行省略绝不叠）、右=时间偏差；无背景无边框，
              // 不抢歌词的戏。整条高约 14px，比三行 chip 省 70px 左右，
              // 等于多显示 1.5 行歌词
              if (showVariant || tips.isNotEmpty || showOffset)
                Padding(
                  padding:
                      const EdgeInsets.only(left: 6, right: 6, bottom: 4),
                  child: Row(
                    children: [
                      if (showVariant)
                        Text(
                          _variantChipText(lyrics.variant),
                          style: _statusStyle(),
                        ),
                      Expanded(
                        child: Text(
                          tips.join('   ·   '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: _statusStyle(),
                        ),
                      ),
                      if (showOffset)
                        Text(
                          '时间偏移 ${_fmtOffsetSec(lyrics.offsetMs)}',
                          style: _statusStyle(),
                        ),
                    ],
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
                      padding: const EdgeInsets.only(top: 4, bottom: 16),
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

/// 状态条文字样式：10.5 号淡白小字——一行承载全部提示，
/// 细看可确认状态（简繁生效/时间偏移），平时几乎不抢歌词的戏
TextStyle _statusStyle() => TextStyle(
      color: Colors.white.withValues(alpha: 0.40),
      fontSize: 10.5,
      height: 1.15,
    );

/// 简繁档位角标文本：词表没就绪时如实说（显示原文），别让用户
/// 以为开关坏了或没保存
String _variantChipText(int v) {
  final cv = ChineseVariantConverter.instance;
  if (!cv.loaded) return '简繁词表未就绪 · 暂显示原文';
  return v == 1 ? '已转简体' : '已转繁体';
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
