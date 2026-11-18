import 'dart:async';

import 'package:flutter/material.dart';

import '../services/player_controller.dart';
import '../services/radio_lyrics.dart';

/// 电台歌词页（待办 L）。
///
/// 与中央信息卡（台标/台名/波形）**互斥**：歌词页开着时这块区域整体
/// 让给歌词，关掉就原样回到信息卡——不叠加、不改动页面其它任何布局。
///
/// 对齐：用 [RadioLyrics.indexAt] 把「播放位置 − 曲名变化时刻」映射到
/// LRC 时间轴。进台第一首没有锚点（不知道唱到哪儿），此时只展示不点亮，
/// 顶部给一行说明；下一首起自动精确同步。
class RadioLyricsStage extends StatefulWidget {
  const RadioLyricsStage({
    super.key,
    required this.controller,
    required this.stationName,
  });

  final PlayerController controller;
  final String stationName;

  @override
  State<RadioLyricsStage> createState() => _RadioLyricsStageState();
}

class _RadioLyricsStageState extends State<RadioLyricsStage> {
  static const double _lineHeight = 54;

  final ScrollController _scroll = ScrollController();
  Timer? _tick;
  int _index = -1;

  @override
  void initState() {
    super.initState();
    // 300ms 一刷：歌词行跨度为秒级，这个频率既跟得上又不费电
    _tick = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (!mounted) return;
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

  @override
  Widget build(BuildContext context) {
    final lyrics = RadioLyrics.instance;
    return AnimatedBuilder(
      animation: lyrics,
      builder: (context, _) {
        if (lyrics.doc == null && !lyrics.querying && !lyrics.notFound) {
          // 开关刚打开、首帧还没拿到曲名：轻提示，不闪空白
          return _shell(
            child: const _Hint(
              icon: Icons.hourglass_empty,
              title: '等待曲目信息…',
              subtitle: '电台推来歌名后会自动查询歌词',
            ),
          );
        }
        if (lyrics.querying) {
          return _shell(
            child: Column(
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
            ),
          );
        }
        if (lyrics.notFound || lyrics.doc == null) {
          return _shell(
            child: _Hint(
              icon: Icons.music_off,
              title: '查无歌词',
              subtitle: lyrics.currentTrack.isEmpty
                  ? '当前没有可用的曲目信息'
                  : '${lyrics.currentTrack}\n换个台或等下一首再试',
            ),
          );
        }
        final doc = lyrics.doc!;
        return _shell(
          child: Column(
            children: [
              if (lyrics.midJoined)
                _TipChip(text: '已中途加入 · 下一首起自动同步'),
              if (!doc.synced)
                _TipChip(text: '这首没有时间轴 · 整段展示'),
              Expanded(
                child: ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  itemCount: doc.lines.length,
                  itemExtent: _lineHeight,
                  physics: lyrics.hasAnchor
                      ? const NeverScrollableScrollPhysics()
                      : const BouncingScrollPhysics(),
                  itemBuilder: (context, i) {
                    final line = doc.lines[i];
                    final active = doc.synced && lyrics.hasAnchor && i == _index;
                    final near = _index >= 0 && (i - _index).abs() <= 1;
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
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
                            fontSize: active ? 21 : 16,
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
            ],
          ),
        );
      },
    );
  }

  Widget _shell({required Widget child}) {
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.2),
          radius: 1.2,
          colors: [Color(0xFF1A1209), Color(0xFF000000)],
        ),
      ),
      child: Column(
        children: [
          // 顶栏：台名 + 歌词标识（台标让位给歌词，只留一行）
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 8),
            child: Row(
              children: [
                Icon(Icons.radio,
                    size: 14, color: Colors.white.withValues(alpha: 0.4)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.stationName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.62),
                      fontSize: 13,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
                Icon(Icons.lyrics_outlined,
                    size: 14, color: Colors.white.withValues(alpha: 0.3)),
                const SizedBox(width: 6),
                Text(
                  '歌词',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.3),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: child),
        ],
      ),
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
          Icon(icon, size: 42, color: Colors.white.withValues(alpha: 0.28)),
          const SizedBox(height: 16),
          Text(
            title,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.8),
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
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
