import 'package:flutter/widgets.dart' show Offset;

/// 非桌面平台占位：无窗口可拖
Future<void> beginWindowDrag({required bool enabled, Offset? local}) async {}

Future<void> updateWindowDrag({Offset? local}) async {}

void endWindowDrag() {}
