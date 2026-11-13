import 'package:flutter/widgets.dart' show Offset;

import 'dart:io';

import 'package:flutter/widgets.dart' show Offset;
import 'package:window_manager/window_manager.dart';

Offset? _dragPointerStart;
Offset? _dragWindowStart;

/// 桌面端：按住鼠标左键拖动窗口（Windows/macOS/Linux）。
///
/// 手动实现（记录按下时的窗口位置与指针位置，拖动中 setPosition 跟手），
/// 不用 windowManager.startDragging()——它走 WM_NCLBUTTONDOWN 让系统
/// 接管移动，在置顶窗口/小窗模式等部分 Windows 环境下不生效
/// （用户实测：小窗和窗口模式都拖不动窗口）。
Future<void> beginWindowDrag(Offset globalPoint) async {
  if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) return;
  try {
    _dragPointerStart = globalPoint;
    _dragWindowStart = await windowManager.getPosition();
  } catch (_) {
    _dragPointerStart = null;
    _dragWindowStart = null;
  }
}

/// 拖动中：窗口新位置 = 起始窗口位置 +（当前指针 - 起始指针）
Future<void> updateWindowDrag(Offset globalPoint) async {
  final p = _dragPointerStart;
  final w = _dragWindowStart;
  if (p == null || w == null) return;
  try {
    await windowManager.setPosition(w + globalPoint - p);
  } catch (_) {}
}

void endWindowDrag() {
  _dragPointerStart = null;
  _dragWindowStart = null;
}
