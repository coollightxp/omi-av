import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 启动动画（简洁版）：
/// - logo 慢速淡入（1.2 秒），落定后轻微呼吸；
/// - 一条暖色光弧贴着图标外圈匀速环绕（约 3 秒一圈）；
/// - 图标背后一层很淡的暖色辉光随光弧呼吸。
///
/// 性能设计：单个 [AnimationController] 无缝循环驱动光弧与呼吸，
/// 淡入用独立的 `CurvedAnimation`，只播一次；`RepaintBoundary` 限定重绘范围。
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
    with TickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  )..repeat();

  // 淡入控制器：只播一次，随 State 释放
  late final AnimationController _fadeCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..forward();

  late final Animation<double> _fade =
      CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);

  @override
  void dispose() {
    _ctrl.dispose();
    _fadeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: Listenable.merge([_ctrl, _fade]),
        builder: (context, _) {
          final t = _ctrl.value;
          final fade = _fade.value;
          return Stack(
            alignment: Alignment.center,
            children: [
              // 环绕光弧（贴图标外圈，匀速一圈）
              CustomPaint(
                size: Size.infinite,
                painter: _RingPainter(
                  t: t,
                  centerOffset: widget.centerOffset,
                  radius: widget.logoSize * 0.72,
                ),
              ),
              // 淡暖辉光（随光弧呼吸）
              Transform.translate(
                offset: widget.centerOffset,
                child: IgnorePointer(
                  child: Container(
                    width: widget.logoSize * 1.7,
                    height: widget.logoSize * 1.7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          const Color(0xFFFF9A4D)
                              .withValues(alpha: 0.16 + 0.08 * math.sin(2 * math.pi * t)),
                          const Color(0x00000000),
                        ],
                        stops: const [0.0, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
              // logo：慢速淡入 + 轻微呼吸（±1.5%）
              Transform.translate(
                offset: widget.centerOffset,
                child: Opacity(
                  opacity: fade,
                  child: Transform.scale(
                    scale: 1.0 +
                        0.015 *
                            math.sin(2 * math.pi * (t / 2) - math.pi / 2) *
                            fade,
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
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 环绕光弧：1/4 圆周的暖色渐变弧，贴图标外圈匀速旋转。
class _RingPainter extends CustomPainter {
  _RingPainter({required this.t, required this.centerOffset, required this.radius});

  final double t;
  final Offset centerOffset;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero) + centerOffset;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(2.0, radius * 0.045)
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: [
          const Color(0xFFFFB35C).withValues(alpha: 0.0),
          const Color(0xFFFFB35C).withValues(alpha: 0.0),
          const Color(0xFFFFC97A).withValues(alpha: 0.75),
          const Color(0xFFFF9A4D).withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.55, 0.8, 1.0],
        transform: const GradientRotation(-math.pi / 2),
      ).createShader(rect);
    canvas.drawArc(rect, 2 * math.pi * t, math.pi / 2, false, paint);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.t != t || old.centerOffset != centerOffset || old.radius != radius;
}
