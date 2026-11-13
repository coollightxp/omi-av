import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Windows 输入框 IME 保险：在两个输入框之间切换焦点后，Windows 引擎的
/// 输入法（TSF）连接偶发失效——表现为无法键入字符、程序对按键不响应
/// （系统相关，部分系统没有；其他 Flutter 程序同样存在）。
/// 点击时先卸载焦点再延时补挂，强制重建 IME 连接，规避该引擎缺陷。
///
/// 2026-11 用户实测：Win10 1607（build 14393）上两个输入框之间切换
/// （先点地址框再回名称框）直接 AppHang 假死→点一下崩溃退出。
///
/// **二次修正**：上一版每个框各自延时 150ms 后无条件 `requestFocus()`，
/// 用户快速来回点时 A 的定时器会把焦点从 B 抢回来，两个框互相拉锯，
/// 表现出来同样是"点了没反应/假死"。现在改用全局序号：
/// 每次点击递增，延时回调只在自己仍是最新一次点击、且期间没有别的
/// 控件拿到焦点时才补挂——不抢别人的焦点。
class ImeSafeTextField extends StatefulWidget {
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final InputDecoration? decoration;
  final TextStyle? style;
  final bool autofocus;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextInputAction? textInputAction;

  const ImeSafeTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.decoration,
    this.style,
    this.autofocus = false,
    this.onChanged,
    this.onSubmitted,
    this.textInputAction,
  });

  @override
  State<ImeSafeTextField> createState() => _ImeSafeTextFieldState();
}

class _ImeSafeTextFieldState extends State<ImeSafeTextField> {
  FocusNode? _ownFocus;

  /// 全局最近一次点击的序号：只有最新一次点击的延时回调有权补挂焦点
  static int _tapSeq = 0;

  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

  /// IME 重连是否启用（仅 Windows 有该缺陷与挂起报告）
  static bool get _needsImeWorkaround =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  @override
  void dispose() {
    _ownFocus?.dispose();
    super.dispose();
  }

  void _onTap() {
    if (!_needsImeWorkaround) return;
    // 已聚焦在本框：再点一次没必要折腾 TSF，交给系统处理光标定位
    if (_focus.hasFocus) return;
    final seq = ++_tapSeq;
    _focus.unfocus();
    Future.delayed(const Duration(milliseconds: 130), () {
      if (!mounted) return;
      // 期间用户点了别的输入框：本次作废，绝不抢焦点
      if (seq != _tapSeq) return;
      final primary = FocusManager.instance.primaryFocus;
      if (primary != null && primary != _focus) return;
      if (!_focus.hasFocus) _focus.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      focusNode: _focus,
      style: widget.style,
      decoration: widget.decoration,
      autofocus: widget.autofocus,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      textInputAction: widget.textInputAction,
      onTap: _needsImeWorkaround ? _onTap : null,
    );
  }

  /// 老系统判定备用：需要按 build 号过滤回退时用
  // ignore: unused_element
  static int get _winBuild {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return 0;
    try {
      final m = RegExp(r'(\d+)\.(\d+)\.(\d+)')
          .firstMatch(Platform.operatingSystemVersion);
      return m != null ? int.tryParse(m.group(3) ?? '0') ?? 0 : 0;
    } catch (_) {
      return 0;
    }
  }
}
