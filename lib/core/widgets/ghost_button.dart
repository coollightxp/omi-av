import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../theme/app_density.dart';
import '../theme/device_profile.dart';

/// ghost 统一按钮：全 App 唯一的圆形操作按钮组件。
///
/// 视觉定稿（视觉现代化）：
/// - 平时透明底 + 白色图标，无边框
/// - 悬停/遥控器高亮/键盘聚焦 → 浮现圆底（白 8%）+ 白描边 + 细发光
/// - 主控钮（播放/暂停）用主色实底；强调钮只放大不加底（录制/播放保持低调）
/// - 触屏按压轻微缩放，无 Material 水波纹
///
/// 尺寸全部来自 AppDensity.buttonSize，组件外禁止传尺寸；
/// 倍率在组件内写死，不开放传参。
enum GhostButtonRole {
  /// 普通操作钮
  normal,

  /// 强调钮：尺寸 ×1.25，仍为透明底（播放/暂停、录制）
  emphasis,

  /// 主控钮：尺寸 ×1.2 + 主色实底（全屏最多一个，当前未启用）
  primary,
}

class GhostButton extends StatefulWidget {
  const GhostButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.role = GhostButtonRole.normal,
    this.selected = false,
    this.iconColor,
    this.autofocus = false,
    this.focusNode,
  });

  final IconData icon;

  /// 悬停提示；桌面端同时承载快捷键标注（如「静音 (M)」）
  final String tooltip;

  /// null = 禁用（置灰且不吃键）
  final VoidCallback? onPressed;

  final GhostButtonRole role;

  /// 外部高亮态：遥控器 ←/→ 选中的钮（面板自己维护高亮 id）。
  /// 与键盘/焦点高亮同一套视觉，避免出现第二种高亮样式。
  final bool selected;

  /// 覆盖图标色：录制中红点、旋转角度提示等状态色用
  final Color? iconColor;

  final bool autofocus;
  final FocusNode? focusNode;

  @override
  State<GhostButton> createState() => _GhostButtonState();
}

class _GhostButtonState extends State<GhostButton> {
  bool _hovering = false;
  bool _pressing = false;

  /// 焦点节点自持时才能安全 dispose（外部传进来的由外部负责）
  FocusNode? _node;
  bool _ownsNode = false;

  @override
  void initState() {
    super.initState();
    _attachNode(widget.focusNode);
  }

  void _attachNode(FocusNode? external) {
    if (external != null) {
      _node = external;
      _ownsNode = false;
    } else {
      _node = FocusNode(debugLabel: 'ghost:${widget.tooltip}');
      _ownsNode = true;
    }
    _node!.addListener(_onFocusChanged);
  }

  void _detachNode() {
    _node?.removeListener(_onFocusChanged);
    if (_ownsNode) _node?.dispose();
    _node = null;
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant GhostButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      _detachNode();
      _attachNode(widget.focusNode);
    }
  }

  @override
  void dispose() {
    _detachNode();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = AppDensity.of(context);
    final isTv = DeviceProfileScope.profileOf(context) == DeviceProfile.tv;

    final mul = switch (widget.role) {
      GhostButtonRole.normal => 1.0,
      GhostButtonRole.emphasis => 1.25,
      GhostButtonRole.primary => 1.2,
    };
    final size = d.buttonSize * mul;

    final enabled = widget.onPressed != null;
    // 焦点态必须读自持的 node：Focus.of(context) 拿到的是祖先节点，
    // 在按钮自身被聚焦时永远是 false（旧实现的缺陷）
    final hasFocus = _node?.hasFocus ?? false;
    final highlighted = _hovering || hasFocus;
    final isPrimary = widget.role == GhostButtonRole.primary;

    final ringOn = widget.selected || (isTv && hasFocus);

    final button = AnimatedScale(
      scale: _pressing ? 0.94 : (ringOn ? 1.06 : 1.0),
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isPrimary && enabled
              ? AppColors.accent
              : (highlighted || widget.selected
                  ? const Color(0x14FFFFFF) // 白 8% 悬浮底
                  : Colors.transparent),
          border: ringOn
              ? Border.all(
                  color: enabled
                      ? AppColors.textPrimary
                      : AppColors.textPrimary.withOpacity(0.35),
                  width: 2)
              : null,
          boxShadow: ringOn
              ? const [
                  BoxShadow(
                    color: AppColors.focusGlow,
                    blurRadius: 8,
                    spreadRadius: 0,
                  ),
                ]
              : null,
        ),
        child: Icon(
          widget.icon,
          size: size * 0.5,
          color: !enabled
              ? AppColors.disabled
              : (widget.iconColor ??
                  (isPrimary ? AppColors.textPrimary : AppColors.textPrimary)),
        ),
      ),
    );

    Widget body = GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _pressing = true) : null,
      onTapCancel: () => setState(() => _pressing = false),
      onTapUp: (_) => setState(() => _pressing = false),
      onTap: widget.onPressed,
      child: Focus(
        focusNode: _node,
        autofocus: widget.autofocus,
        canRequestFocus: enabled,
        onKeyEvent: _handleKey,
        child: button,
      ),
    );

    // 触屏/电视端不加 Tooltip（会挡住小窗画面，且无悬停概念）
    if (isTv || MediaQuery.of(context).size.shortestSide < 500) {
      return Semantics(button: true, label: widget.tooltip, child: body);
    }

    return Semantics(
      button: true,
      label: widget.tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: Tooltip(
          message: widget.tooltip,
          waitDuration: const Duration(milliseconds: 450),
          child: body,
        ),
      ),
    );
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    // 统一吃掉 OK/Enter/空格，杜绝冒泡到播放器（焦点穿透防御）
    if (event is KeyUpEvent || event is KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (widget.onPressed == null) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space) {
      widget.onPressed?.call();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}
