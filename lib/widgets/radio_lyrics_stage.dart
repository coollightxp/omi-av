import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../services/player_controller.dart';
import '../services/radio_lyrics.dart';

/// 电台歌词块（待办 L · 分栏版式定稿）。
///
/// 不再独占整屏：作为右侧的一块圆角面板，放在原中央信息卡（现在靠左）
/// 旁边——左"台"右"词"，互不遮挡。面板自身不满屏，尺寸由
/// [video_player_widget] 的分栏布局（`_lyricsSplit`）给定，窄屏随
/// 整版等比缩小。之前的顶栏（左上角台名/右上角"歌词"小字）已按
/// 用户要求去掉——台名在左侧信息卡里本来就有，不重复占地方。
///
/// 对齐：用 [RadioLyrics.indexAt] 把「播放位置 − 曲名变化时刻」映射到
/// LRC 时间轴。进台第一首没有锚点（不知道唱到哪儿），此时只展示不点亮，
/// 面板内给一行说明；下一首起自动精确同步。
class RadioLyricsStage extends StatefulWidget {
  const RadioLyricsStage({super.key, required this.controller});

  final PlayerController controller;

  @override
  State<RadioLyricsStage> createState() => _RadioLyricsStageState();
}

class _RadioLyricsStageState extends State<RadioLyricsStage> {
  static const double _lineHeight = 48;
  static const double _topPad = 16;

  final ScrollController _scroll = ScrollController();
  Timer? _tick;
  int _index = -1;

  /// 用户正在手动拨动/拖拽歌词：期间暂停自动跟随与自动滚动，
  /// 松手后以视口中央那一行为准重新对时（不抢用户的手）
  bool _manual = false;

  /// 刚校准完的两秒提示
  bool _aligned = false;
  Timer? _alignedTimer;

  @override
  void initState() {
    super.initState();
    // 300ms 一刷：歌词行跨度为秒级，这个频率既跟得上又不费电
    _tick = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (!mounted) return;
      if (_manual) return; // 手在拨：不抢、不跳
      final i = RadioLyrics.instance.indexAt(widget.controller.position);
      if (i != _index) {
        setState(() => _index = i);
        _scrollTo(i);
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _alignedTimer?.cancel();
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

  /// 手动拨动开始 → 冻结自动跟随；松手 → 以中间那行重新对时。
  ///
  /// 只为「用户主动拖」触发：自动 animateTo 的 start/end 通知不带
  /// dragDetails，不会被误判成手动。
  bool _onScroll(ScrollNotification n) {
    if (n is ScrollStartNotification && n.dragDetails != null) {
      _manual = true;
    } else if (n is ScrollEndNotification && _manual) {
      _manual = false;
      _alignToCenter();
    }
    return false;
  }

  /// 把视口正中间那一行当作「此刻正在唱的句子」，重设锚点。
  /// 长前奏/推流时间偏的情况，用户拨到正确那句松手即可，之后自动跟。
  void _alignToCenter() {
    final lyrics = RadioLyrics.instance;
    final doc = lyrics.doc;
    if (doc == null || !doc.synced || doc.lines.isEmpty) return;
    if (!_scroll.hasClients) return;
    final center =
        _scroll.offset + _scroll.position.viewportDimension / 2 - _topPad;
    final i = (center / _lineHeight)
        .floor()
        .clamp(0, doc.lines.length - 1);
    lyrics.realign(i, widget.controller.position);
    if (!mounted) return;
    setState(() {
      _index = i;
      _aligned = true;
    });
    _alignedTimer?.cancel();
    _alignedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _aligned = false);
    });
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
          body = Column(
            children: [
              if (lyrics.midJoined)
                const _TipChip(text: '已中途加入 · 下一首起自动同步'),
              if (!doc.synced) const _TipChip(text: '这首没有时间轴 · 整段展示'),
              if (_aligned) const _TipChip(text: '已对齐 · 从此继续自动同步'),
              Expanded(
                child: ScrollConfiguration(
                  // ① dragDevices 加上 mouse：桌面端默认鼠标拖不动列表，
                  //    加上后 Windows 能直接拽歌词；② scrollbars: false
                  //    去掉滚动时旁边冒出来的滑条（用户要求）
                  behavior: ScrollConfiguration.of(context).copyWith(
                    dragDevices: {
                      PointerDeviceKind.touch,
                      PointerDeviceKind.mouse,
                      PointerDeviceKind.stylus,
                      PointerDeviceKind.trackpad,
                    },
                    scrollbars: false,
                  ),
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _onScroll,
                    child: ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(vertical: _topPad),
                      itemCount: doc.lines.length,
                      itemExtent: _lineHeight,
                      // 可拖校准只在桌面（Windows 鼠标拖拽）。
                      // 手机上关闭：整个屏幕右侧上滑是调音量、左侧调亮度，
                      // 歌词块占了右半边，若在这里滚歌词会跟音量手势打架
                      // （用户定稿：手机不做校准，桌面保留）
                      physics: widget.controller.isDesktop
                          ? const ClampingScrollPhysics()
                          : const NeverScrollableScrollPhysics(),
                      itemBuilder: (context, i) {
                    final line = doc.lines[i];
                    final active = doc.synced && lyrics.hasAnchor && i == _index;
                    final near = _index >= 0 && (i - _index).abs() <= 1;
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
                                    alpha: near ? 0.55 : 0.26),
                            fontSize: active ? 19 : 15,
                            height: 1.35,
                            fontWeight:
                                active ? FontWeight.w700 : FontWeight.w400,
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

class _TipChip extends StatelessWidget {
  const _TipChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.55),
          fontSize: 11.5,
        ),
      ),
    );
  }
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
