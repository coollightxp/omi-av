import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/app_colors.dart';

/// 电台「正在出声」可视化（方案 12.3）。
///
/// 关于"真实频谱"：media_kit(libmpv) / video_player 都只给控制面和
/// 元数据，不向 Dart 层吐 PCM 样本，做不了真 FFT。要真谱只能写原生
/// 采集（Windows WASAPI loopback / Android Visualizer），成本与风险
/// 都远高于这一屏的收益，所以这里做的是**电平表式模拟**：
///
/// - 每根柱子有自己的相位、速度和包络，互不同步 → 不会看出循环；
/// - 上升快、回落慢（14 : 5 的阻尼比），像真实电平表的惯性；
/// - 暂停时整体能量平滑收到 0，柱子压成静止细线，ticker 自动停；
/// - 起播时从 0 涨起来，不会突然跳满。
///
/// 只在 paint 阶段算高度，不重建 widget 树，25 根柱 60fps 成本可忽略。
class AudioWave extends StatefulWidget {
  const AudioWave({
    super.key,
    required this.active,
    this.bars = 27,
    this.height = 50,
    this.barWidth = 3.2,
    this.gap = 4.8,
    this.color = AppColors.wave,
  });

  /// 是否正在播放（false 时整条波压平为静止基线）
  final bool active;
  final int bars;
  final double height;
  final double barWidth;
  final double gap;
  final Color color;

  @override
  State<AudioWave> createState() => _AudioWaveState();
}

class _Bar {
  _Bar(this.env, this.speed, this.offset) : phase = offset;

  /// 两端收窄的包络（中间高）
  final double env;
  final double speed;
  final double offset;
  double phase;
  double level = 0;
}

class _AudioWaveState extends State<AudioWave>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final math.Random _rnd = math.Random(20251112);
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);

  late List<_Bar> _bars;
  double _energy = 0;
  Duration _last = Duration.zero;

  @override
  void initState() {
    super.initState();
    _bars = _buildBars();
    if (widget.active) _start();
  }

  List<_Bar> _buildBars() {
    final n = widget.bars;
    return List<_Bar>.generate(n, (i) {
      final f = n == 1 ? 0.5 : i / (n - 1);
      // 中间高两侧低，像一条被"压住"的声波，不是死板的等宽柱
      final env = 0.32 + 0.68 * math.sin(math.pi * f);
      // 速度取互不相同的值（0.35~1.45Hz），避免整排同步呼吸
      final speed = 0.35 + _rnd.nextDouble() * 1.10;
      final offset = _rnd.nextDouble() * math.pi * 2;
      return _Bar(env, speed, offset);
    });
  }

  void _start() {
    if (_ticker.isActive) return;
    _last = Duration.zero;
    _ticker.start();
  }

  void _tick(Duration elapsed) {
    final raw =
        _last == Duration.zero ? 0.016 : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    final step = raw.clamp(0.001, 0.05);

    final goal = widget.active ? 1.0 : 0.0;
    _energy += (goal - _energy) * (step * 3.4).clamp(0.0, 1.0);

    for (final b in _bars) {
      b.phase += step * b.speed * 2 * math.pi;
      // 两条不同频正弦叠加 → 不规则起伏；再乘包络
      final w = 0.5 +
          0.32 * math.sin(b.phase) +
          0.18 * math.sin(b.phase * 1.73 + b.offset);
      final target = b.env * (0.10 + 0.90 * w.clamp(0.0, 1.0)) * _energy;
      // 上升快、回落慢：电平表手感
      final k = target > b.level ? 14.0 : 5.0;
      b.level += (target - b.level) * (step * k).clamp(0.0, 1.0);
    }
    _frame.value++;

    // 暂停且已收干净：停表，别在暂停页空转 60fps
    if (!widget.active && _energy < 0.004) {
      _energy = 0;
      for (final b in _bars) {
        b.level = 0;
      }
      _frame.value++;
      _ticker.stop();
    }
  }

  @override
  void didUpdateWidget(covariant AudioWave oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width =
        widget.bars * widget.barWidth + (widget.bars - 1) * widget.gap;
    return SizedBox(
      width: width,
      height: widget.height,
      child: ValueListenableBuilder<int>(
        valueListenable: _frame,
        builder: (context, _, __) => CustomPaint(
          painter: _WavePainter(
            levels: [for (final b in _bars) b.level],
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
    required this.levels,
    required this.barWidth,
    required this.gap,
    required this.color,
  });

  final List<double> levels;
  final double barWidth;
  final double gap;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final n = levels.length;
    if (n == 0) return;
    final totalW = n * barWidth + (n - 1) * gap;
    final left = (size.width - totalW) / 2;
    final maxH = size.height;
    final cy = maxH / 2;
    final paint = Paint()..style = PaintingStyle.fill;
    final radius = Radius.circular(barWidth / 2);

    for (var i = 0; i < n; i++) {
      final ratio = levels[i].clamp(0.0, 1.0);
      final h = math.max(2.4, maxH * (0.06 + 0.94 * ratio));
      final x = left + i * (barWidth + gap);
      paint.color = Color.lerp(color, Colors.white, 0.32 * ratio)!
          .withValues(alpha: 0.28 + 0.62 * ratio);
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
  bool shouldRepaint(covariant _WavePainter old) => true;
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
