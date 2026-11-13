import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Windows 输入框 IME 保险：在两个输入框之间切换焦点后，Windows 引擎的
/// 输入法（TSF）连接偶发失效——表现为无法键入字符、程序对按键不响应
/// （系统相关，部分系统没有；其他 Flutter 程序同样存在）。
/// 点击时先卸载焦点再延时补挂，强制重建 IME 连接，规避该引擎缺陷。
///
/// 2026-11 用户实测：Win10 1607（build 14393）上两个输入框之间切换
/// （先点地址框再回名称框）直接 AppHang 假死→点一下崩溃退出。原方案
/// 1607 跳过重连已不够——现状是必挂，重连版只会更好；延时从 30ms
/// 放宽到 150ms，给 TSF 拆连接留足时间。若某系统反而加重，回退点：
/// [_needsImeWorkaround] 按 build 号过滤即可。
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

  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

  /// IME 重连是否启用（仅 Windows 有该缺陷与挂起报告）
  static bool get _needsImeWorkaround =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  @override
  void dispose() {
    _ownFocus?.dispose();
    super.dispose();
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
      onTap: !_needsImeWorkaround
          ? null
          : () {
              _focus.unfocus();
              Future.delayed(const Duration(milliseconds: 150), () {
                if (mounted && !_focus.hasFocus) _focus.requestFocus();
              });
            },
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
