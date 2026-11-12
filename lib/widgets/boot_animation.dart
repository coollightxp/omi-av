import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 启动图标：呼吸灯形式。
///
/// 图标亮度循环显亮/渐暗（约 2.4 秒一个呼吸周期），持续运行，
/// 直到初始化完毕、启动画面被撤掉为止。
/// 单个 [AnimationController] 无缝循环驱动，`RepaintBoundary` 限定重绘范围。
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
    duration: const Duration(milliseconds: 2400),
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
          // 呼吸灯：0（暗）→ 1（亮）→ 0，余弦平滑，循环无缝
          final breath = 0.5 - 0.5 * math.cos(2 * math.pi * t);
          return Transform.translate(
            offset: widget.centerOffset,
            child: SizedBox(
              width: widget.logoSize,
              height: widget.logoSize,
              child: Opacity(
                // 图标本体的呼吸显亮（无光晕：光晕易显脏画面）
                opacity: 0.35 + 0.65 * breath,
                child: Image.asset(
                  'branding/splash.png',
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
