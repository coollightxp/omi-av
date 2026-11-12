import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../theme/app_density.dart';

/// ghost 统一按钮：全 App 唯一的圆形操作按钮组件。
///
/// 视觉定稿（视觉现代化）：
/// - 平时透明底 + 白色图标，无边框
/// - 悬停/聚焦浮现圆底（白 8%）；TV 焦点态放大 1.05 + 发光描边
/// - 主控钮（播放/暂停）用主色实底 + 1.2 倍尺寸，全屏最多一个
/// - 触屏按压轻微缩放，无 Material 水波纹
///
/// 尺寸全部来自 AppDensity.buttonSize，组件外禁止传尺寸；
/// 倍率在组件内写死，不开放传参。
enum GhostButtonRole { normal, primary }

class GhostButton extends StatefulWidget {
  const GhostButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.role = GhostButtonRole.normal,
    this.enabled = true,
    this.autofocus = false,
    this.focusNode,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final GhostButtonRole role;
  final bool enabled;
  final bool autofocus;
  final FocusNode? focusNode;

  @override
  State<GhostButton> createState() => _GhostButtonState();
}

class _GhostButtonState extends State<GhostButton> {
  bool _hovering = false;
  bool _pressing = false;

  @override
  Widget build(BuildContext context) {
    final d = AppDensity.of(context);
    final profile = DeviceProfileScope.profileOf(context);

    final isPrimary = widget.role == GhostButtonRole.primary;
    final isTv = profile == DeviceProfile.tv;

    // 尺寸：基准 × (主控 1.2)；电视档基准值本身已大，不再乘滑块避免溢出
    final size = d.buttonSize * (isPrimary ? 1.2 : 1.0);

    final hasFocus = Focus.of(context)?.hasFocus ?? false;
    final highlighted = _hovering || hasFocus;

    final button = AnimatedScale(
      scale: _pressing ? 0.96 : (isTv && hasFocus ? 1.05 : 1.0),
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isPrimary
              ? AppColors.accent
              : (highlighted
                  ? const Color(0x14FFFFFF) // 白 8% 悬浮底
                  : Colors.transparent),
          border: (isTv && hasFocus)
              ? Border.all(color: AppColors.textPrimary, width: 2)
              : null,
          boxShadow: (isTv && hasFocus)
              ? const [
                  BoxShadow(
                    color: AppColors.focusGlow,
                    blurRadius: 12,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: Icon(
          widget.icon,
          size: size * 0.5,
          color: widget.enabled
              ? (isPrimary ? AppColors.textPrimary : AppColors.textSecondary)
              : AppColors.disabled,
        ),
      ),
    );

    return Semantics(
      button: true,
      label: widget.tooltip,
      child: MouseRegion(
        cursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _pressing = true),
          onTapCancel: () => setState(() => _pressing = false),
          onTapUp: (_) => setState(() => _pressing = false),
          onTap: widget.enabled ? widget.onPressed : null,
          child: Focus(
            focusNode: widget.focusNode,
            autofocus: widget.autofocus,
            onKeyEvent: _handleKey,
            child: Tooltip(
              message: widget.tooltip,
              waitDuration: const Duration(milliseconds: 500),
              child: button,
            ),
          ),
        ),
      ),
    );
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    // 统一吃掉 OK/Enter/空格，杜绝冒泡到播放器（焦点穿透防御）
    if (event is KeyUpEvent || event is KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if ((key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.space) &&
        widget.enabled) {
      widget.onPressed?.call();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}
