import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// 电台「正在出声」可视化（方案 12.3）。
///
/// 为什么不是真频谱：media_kit / video_player 都不对外暴露 PCM 样本，
/// 上层拿不到音频数据，做不了真实 FFT。这里用多路互质频率的正弦叠加
/// 生成有机起伏，由 [active] 驱动——播放时起伏、暂停时收成一条静止细线。
/// 只在 paint 阶段算高度，不重建 widget 树，60fps 开销可忽略。
class AudioWave extends StatefulWidget {
  const AudioWave({
    super.key,
    required this.active,
    this.bars = 27,
    this.height = 50,
    this.barWidth = 3.2,
    this.gap = 4.8,
    this.color = AppColors.wave,
    this.alignment = MainAxisAlignment.center,
  });

  /// 是否正在播放（false 时整条波压平为静止基线）
  final bool active;
  final int bars;
  final double height;
  final double barWidth;
  final double gap;
  final Color color;
  final MainAxisAlignment alignment;

  @override
  State<AudioWave> createState() => _AudioWaveState();
}

class _AudioWaveState extends State<AudioWave> with TickerProviderStateMixin {
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    value: widget.active ? 1 : 0,
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _wave.repeat();
  }

  @override
  void didUpdateWidget(covariant AudioWave oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active == oldWidget.active) return;
    // 暂停：先把振幅平滑收掉再停表；恢复：先起来再动
    if (widget.active) {
      _fade.forward();
      if (!_wave.isAnimating) _wave.repeat();
    } else {
      // 收干净后把表停掉：暂停中的电台不该一直占一个 60fps 的 ticker
      _fade.reverse().whenComplete(() {
        if (mounted && !widget.active) _wave.stop();
      });
    }
  }

  @override
  void dispose() {
    _wave.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width =
        widget.bars * widget.barWidth + (widget.bars - 1) * widget.gap;
    return SizedBox(
      width: width,
      height: widget.height,
      child: AnimatedBuilder(
        animation: Listenable.merge([_wave, _fade]),
        builder: (context, _) => CustomPaint(
          painter: _WavePainter(
            phase: _wave.value * 2 * math.pi,
            fade: Curves.easeOut.transform(_fade.value),
            bars: widget.bars,
            barWidth: widget.barWidth,
            gap: widget.gap,
            color: widget.color,
          ),
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({
    required this.phase,
    required this.fade,
    required this.bars,
    required this.barWidth,
    required this.gap,
    required this.color,
  });

  final double phase;
  final double fade;
  final int bars;
  final double barWidth;
  final double gap;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final n = bars;
    if (n <= 0) return;
    final totalW = n * barWidth + (n - 1) * gap;
    final left = (size.width - totalW) / 2;
    final maxH = size.height;
    final cy = maxH / 2;
    final paint = Paint()..style = PaintingStyle.fill;
    final radius = Radius.circular(barWidth / 2);

    for (var i = 0; i < n; i++) {
      final f = n == 1 ? 0.5 : i / (n - 1);
      // 两端收窄的包络：中间高、两侧低，像一条被压住的声波
      final env = 0.30 + 0.70 * math.sin(math.pi * f);
      final ph = i * 0.62;
      final v = 0.5 +
          0.27 * math.sin(phase * 1.00 + ph) +
          0.15 * math.sin(phase * 2.37 + ph * 1.7 + 1.1) +
          0.08 * math.sin(phase * 4.13 + ph * 2.3 + 2.2);
      final e = v.clamp(0.0, 1.0) * env * fade;
      final h = (maxH * (0.07 + 0.93 * e)).clamp(2.4, maxH);
      final x = left + i * (barWidth + gap);
      paint.color = Color.lerp(color, Colors.white, 0.30 * (h / maxH))!
          .withValues(alpha: 0.30 + 0.62 * (h / maxH));
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, cy - h / 2, barWidth, h),
          radius,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.phase != phase ||
      old.fade != fade ||
      old.bars != bars ||
      old.color != color ||
      old.barWidth != barWidth ||
      old.gap != gap;
}

/// 迷你跳动条：给徽章/状态行用，3~4 根、十几像素高。
/// 同一个绘法，参数缩小，视觉上与大波形是一家人。
class AudioBars extends StatelessWidget {
  const AudioBars({
    super.key,
    required this.active,
    this.color = AppColors.wave,
    this.height = 12,
    this.bars = 3,
    this.barWidth = 2.6,
    this.gap = 2.4,
  });

  final bool active;
  final Color color;
  final double height;
  final int bars;
  final double barWidth;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return AudioWave(
      active: active,
      bars: bars,
      height: height,
      barWidth: barWidth,
      gap: gap,
      color: color,
    );
  }
}
