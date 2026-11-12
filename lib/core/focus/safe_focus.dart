import 'package:flutter/widgets.dart';

/// 安全地请求焦点：包在 postFrameCallback 里，规避对尚未 build 完成
/// 的 FocusNode 调 requestFocus 静默失败的隐形坑。
///
/// 全项目统一使用此函数，禁止直接调用 node.requestFocus()。
void safeRequestFocus(FocusNode node) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (node.context != null) {
      node.requestFocus();
    }
  });
}
