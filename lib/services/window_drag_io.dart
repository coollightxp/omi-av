import 'dart:ffi' as ffi;
import 'dart:io' show Platform;

import 'package:flutter/widgets.dart' show Offset, WidgetsBinding;
import 'package:ffi/ffi.dart' show calloc;
import 'package:window_manager/window_manager.dart';

/// 桌面端：按住鼠标拖动窗口（Windows）。
///
/// 为什么不能只用 Flutter 事件：Flutter 的 globalPosition 是「窗口内
/// 相对坐标」，窗口跟着鼠标走后同一物理位置对应的相对坐标不变，
/// 手动 setPosition 永远算出零位移（v2.1.16 实测拖不动）；
/// windowManager.startDragging 在置顶/无边框窗口下也时不时不生效
/// （v2.1.14/15 实测）。这里改用 Win32 GetCursorPos 拿屏幕物理坐标，
/// 配合窗口逻辑坐标手动跟手，两条路都不依赖 Flutter 坐标系。
final class _POINT extends ffi.Struct {
  @ffi.Long()
  external int x;

  @ffi.Long()
  external int y;
}

typedef _GetCursorPosC = ffi.Int32 Function(ffi.Pointer<_POINT>);
typedef _GetCursorPosDart = int Function(ffi.Pointer<_POINT>);

_GetCursorPosDart? _getCursorPos;
bool _ffiBroken = false;

ffi.Pointer<_POINT>? _ptBuf;

int? _screenX() {
  if (_ffiBroken) return null;
  try {
    _getCursorPos ??= () {
      final user32 = ffi.DynamicLibrary.open('user32.dll');
      final fn = user32
          .lookupFunction<_GetCursorPosC, _GetCursorPosDart>('GetCursorPos');
      _ptBuf = calloc<_POINT>();
      return fn;
    }();
    final ok = _getCursorPos!(_ptBuf!);
    if (ok == 0) return null;
    return _ptBuf!.ref.x;
  } catch (_) {
    _ffiBroken = true;
    return null;
  }
}

int? _screenY() {
  _screenX(); // 顺带初始化
  if (_ffiBroken || _ptBuf == null) return null;
  return _ptBuf!.ref.y;
}

/// 按下：[enabled] 为 false 时直接不武装（非桌面/全屏/网页区）。
/// 记录按下时的光标屏幕坐标与窗口逻辑坐标，移动量全部由二者推出。
///
/// 光标坐标同步取（GetCursorPos 是同步 FFI），窗口坐标要 await；用
/// [_armGen] 作废早期请求——手快时上一次按下的 await 可能晚于这一次落地。
Future<void> beginWindowDrag({required bool enabled}) async {
  final gen = ++_armGen;
  _dragArmed = false;
  _dragStarted = false;
  _downCursor = null;
  _downWindow = null;
  if (!enabled || !Platform.isWindows) return;
  final x = _screenX();
  final y = _screenY();
  if (x == null || y == null) return;
  final cur = Offset(x.toDouble(), y.toDouble());
  try {
    final pos = await windowManager.getPosition();
    if (gen != _armGen) return; // 期间又按下/松开了，本次作废
    _downCursor = cur;
    _downWindow = pos;
    _dragArmed = true;
  } catch (_) {
    _dragArmed = false;
  }
}

int _armGen = 0;

bool _dragArmed = false;
bool _dragStarted = false;
Offset? _downCursor;
Offset? _downWindow;

/// 移动：光标离按下点超过 4 物理像素才开始真正拖（避免单击带歪窗口）。
/// 位移用「屏幕物理像素差 ÷ devicePixelRatio」换算成窗口逻辑坐标。
Future<void> updateWindowDrag() async {
  if (!_dragArmed || _busy) return;
  final x = _screenX();
  final y = _screenY();
  final d = _downCursor;
  final w0 = _downWindow;
  if (x == null || y == null || d == null || w0 == null) return;
  final dx = x - d.dx;
  final dy = y - d.dy;
  if (!_dragStarted) {
    if (dx * dx + dy * dy < 16) return;
    _dragStarted = true;
  }
  final dpr = WidgetsBinding
          .instance.platformDispatcher.implicitView?.devicePixelRatio ??
      1.0;
  // 一次只发一个 setPosition：指针事件比窗口移动快时排队会拖成橡皮筋
  _busy = true;
  try {
    await windowManager.setPosition(Offset(w0.dx + dx / dpr, w0.dy + dy / dpr),
        animate: false);
  } catch (_) {
  } finally {
    _busy = false;
  }
}

bool _busy = false;

void endWindowDrag() {
  _armGen++;
  _dragArmed = false;
  _dragStarted = false;
  _downCursor = null;
  _downWindow = null;
}
