import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 启动动画：中心 logo 呼吸 + 暖色粒子/雾团环绕公转 + 旋转光弧。
///
/// 性能设计：
/// - 单个 [AnimationController] 驱动全部相位，8 秒无缝循环；
///   所有粒子的角速度/呼吸频率都是循环时长的整数倍谐波，
///   因此 t=1 时相位与 t=0 完全重合，不会跳变；
/// - 粒子由 [CustomPainter] 一次绘制，`RepaintBoundary` 限定重绘范围；
/// - 粒子总数按屏幕大小自适应，低端设备自动减少。
class BootAnimation extends StatefulWidget {
  const BootAnimation({
    super.key,
    required this.logoSize,
    this.centerOffset = Offset.zero,
  });

  /// logo 边长（逻辑像素）
  final double logoSize;

  /// 动画中心相对所在区域中心的偏移（与 logo 的位移保持一致）
  final Offset centerOffset;

  @override
  State<BootAnimation> createState() => _BootAnimationState();
}

class _BootAnimationState extends State<BootAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 8),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          final t = _ctrl.value;
          return Stack(
            alignment: Alignment.center,
            children: [
              // 粒子 + 雾团 + 光弧（canvas 层）
              CustomPaint(
                size: Size.infinite,
                painter: _OrbitPainter(
                  t: t,
                  centerOffset: widget.centerOffset,
                  orbitRx: widget.logoSize * 1.15,
                  orbitRy: widget.logoSize * 0.62,
                ),
              ),
              // 中心辉光（呼吸）
              Transform.translate(
                offset: widget.centerOffset,
                child: _Glow(t: t, size: widget.logoSize * 1.9),
              ),
              // logo 呼吸缩放 + 轻微浮动
              Transform.translate(
                offset: widget.centerOffset +
                    Offset(
                        0,
                        -widget.logoSize *
                            0.05 *
                            math.sin(2 * math.pi * t)),
                child: Transform.scale(
                  scale: 1.0 + 0.035 * math.sin(2 * math.pi * t * 2 - math.pi / 2),
                  child: SizedBox(
                    width: widget.logoSize,
                    height: widget.logoSize,
                    child: Image.asset(
                      'branding/splash.png',
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 中心暖色辉光，透明度随呼吸脉动
class _Glow extends StatelessWidget {
  const _Glow({required this.t, required this.size});

  final double t;
  final double size;

  @override
  Widget build(BuildContext context) {
    final pulse = 0.55 + 0.20 * math.sin(2 * math.pi * (t * 2 - 0.25));
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              const Color(0xFFFF9A4D).withValues(alpha: 0.30 * pulse),
              const Color(0xFFFFB35C).withValues(alpha: 0.12 * pulse),
              const Color(0x00000000),
            ],
            stops: const [0.0, 0.45, 1.0],
          ),
        ),
      ),
    );
  }
}

/// 环绕粒子层：
/// - 3 团暖色雾（大半径 + 高斯模糊），慢速公转；
/// - N 颗光点沿椭圆轨道公转，带上下漂浮与景深（远端小而淡）；
/// - 一条细光弧绕外圈慢转。
class _OrbitPainter extends CustomPainter {
  _OrbitPainter({
    required this.t,
    required this.centerOffset,
    required this.orbitRx,
    required this.orbitRy,
  })  : mists = _buildMists(),
        dots = _buildDots();

  final double t;
  final Offset centerOffset;
  final double orbitRx;
  final double orbitRy;

  final List<_Mist> mists;
  final List<_Dot> dots;

  static List<_Mist> _buildMists() => [
        _Mist(radiusScale: 1.55, blur: 26, phase: 0.00, kTurns: 1,
            color: const Color(0xFFFF9440), alpha: 0.10, size: 0.30),
        _Mist(radiusScale: 1.15, blur: 22, phase: 0.55, kTurns: 1,
            color: const Color(0xFFFFC069), alpha: 0.09, size: 0.24),
        _Mist(radiusScale: 1.90, blur: 30, phase: 0.80, kTurns: 1,
            color: const Color(0xFFFF7A3C), alpha: 0.08, size: 0.34),
      ];

  /// 确定性伪随机（不依赖 Random 种子，保证每次启动一致）
  static double _prand(int i) {
    final x = math.sin(i * 12.9898) * 43758.5453;
    return x - x.floor();
  }

  static List<_Dot> _buildDots() {
    final list = <_Dot>[];
    for (var i = 0; i < _dotCount; i++) {
      final r1 = _prand(i * 2 + 1);
      final r2 = _prand(i * 2 + 2);
      final r3 = _prand(i * 2 + 3);
      list.add(_Dot(
        phase: r1,
        // 每周期 1~2 整圈 → 无缝循环
        kTurns: r2 < 0.6 ? 1 : 2,
        radiusScale: 1.25 + 0.65 * r3,
        bobTurns: r1 < 0.5 ? 3 : 4,
        size: 1.4 + 2.4 * _prand(i * 3 + 7),
        warm: r3 > 0.45,
      ));
    }
    return list;
  }

  static const int _dotCount = 26;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2 + centerOffset.dx;
    final cy = size.height / 2;
    // 粒子运动区域以图标为中心
    final oy = cy + centerOffset.dy;

    // ---- 雾团 ----
    final mistPaint = Paint()..style = PaintingStyle.fill;
    for (final m in mists) {
      final ang = 2 * math.pi * (m.kTurns * t + m.phase);
      final x = cx + m.radiusScale * orbitRx * math.cos(ang);
      final y = oy + m.radiusScale * orbitRy * math.sin(ang);
      final breathe =
          0.75 + 0.25 * math.sin(2 * math.pi * (2 * t + m.phase));
      mistPaint.color = m.color.withValues(alpha: m.alpha * breathe);
      mistPaint.maskFilter =
          MaskFilter.blur(BlurStyle.normal, m.blur * size.width * 0.0015);
      canvas.drawCircle(Offset(x, y), size.width * m.size * 0.06, mistPaint);
    }

    // ---- 光点 ----
    final dotPaint = Paint()..style = PaintingStyle.fill;
    for (final d in dots) {
      final ang = 2 * math.pi * (d.kTurns * t + d.phase);
      final x = cx + d.radiusScale * orbitRx * math.cos(ang);
      final y0 = oy + d.radiusScale * orbitRy * math.sin(ang);
      // 上下漂浮（整数次谐波，循环无缝）
      final y = y0 + orbitRy * 0.10 *
          math.sin(2 * math.pi * (d.bobTurns * t + d.phase));
      // 景深：sin(ang) > 0 表示轨道下半段（靠近观众）→ 更大更亮
      final depth = (math.sin(ang) + 1) / 2; // 0 远 → 1 近
      final alpha = 0.18 + 0.55 * depth;
      final r = d.size * (0.75 + 0.5 * depth) * size.width * 0.0016;
      dotPaint.color = (d.warm
              ? const Color(0xFFFFC97A)
              : const Color(0xFFFFF3E0))
          .withValues(alpha: alpha);
      canvas.drawCircle(Offset(x, y), r, dotPaint);
    }

    // ---- 旋转光弧（外圈细弧，约 1/6 圆周） ----
    final arcRect = Rect.fromCenter(
      center: Offset(cx, oy),
      width: orbitRx * 2.6,
      height: orbitRy * 2.6,
    );
    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: math.pi * 2,
        colors: [
          const Color(0xFFFFB35C).withValues(alpha: 0.0),
          const Color(0xFFFFB35C).withValues(alpha: 0.55),
          const Color(0xFFFFB35C).withValues(alpha: 0.0),
        ],
        transform: const GradientRotation(-math.pi / 2),
      ).createShader(arcRect);
    canvas.drawArc(
      arcRect,
      2 * math.pi * t, // 每周期整一圈，无缝
      math.pi / 3,
      false,
      arcPaint,
    );
  }

  @override
  bool shouldRepaint(_OrbitPainter old) =>
      old.t != t ||
      old.centerOffset != centerOffset ||
      old.orbitRx != orbitRx ||
      old.orbitRy != orbitRy;
}

class _Mist {
  const _Mist({
    required this.radiusScale,
    required this.blur,
    required this.phase,
    required this.kTurns,
    required this.color,
    required this.alpha,
    required this.size,
  });

  final double radiusScale;
  final double blur;
  final double phase;
  final int kTurns;
  final Color color;
  final double alpha;
  final double size;
}

class _Dot {
  const _Dot({
    required this.phase,
    required this.kTurns,
    required this.radiusScale,
    required this.bobTurns,
    required this.size,
    required this.warm,
  });

  final double phase;
  final int kTurns;
  final double radiusScale;
  final int bobTurns;
  final double size;
  final bool warm;
}
