import 'dart:ffi' as ffi;
import 'dart:io' show Platform;

import 'package:flutter/widgets.dart' show Offset, WidgetsBinding;
import 'package:ffi/ffi.dart' show calloc;
import 'package:window_manager/window_manager.dart';

/// 桌面端：按住鼠标拖动窗口（Windows）。
///
/// 两条路，按可靠性排序：
///
/// 1. **原生拖动（首选）**：位移超过阈值后调 `windowManager.startDragging()`
///    （内部 ReleaseCapture + WM_NCLBUTTONDOWN/HTCAPTION），由 Windows 自己
///    接管整段拖动。不依赖后续指针事件——手动 setPosition 方案里窗口一动，
///    指针相对坐标就不变了，个别机器还会收到 PointerCancel，表现为
///    「抖一下就不动」。
/// 2. **手动跟手（兜底）**：原生调用异常时，用 Win32 `GetCursorPos` 取屏幕
///    物理坐标，位移 ÷ devicePixelRatio 后 setPosition。
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

/// 按下：记录按下点的窗口内坐标 [local] 与光标屏幕坐标。
///
/// [enabled] 为 false 直接不武装（全屏/网页区/非桌面）。
/// 光标坐标同步取（GetCursorPos 是同步 FFI）；窗口坐标要 await，用
/// [_armGen] 作废过期请求——手快时上一次按下的 await 可能晚于这一次落地。
Future<void> beginWindowDrag({
  required bool enabled,
  Offset? local,
}) async {
  final gen = ++_armGen;
  _dragArmed = false;
  _dragStarted = false;
  _nativeTried = false;
  _downCursor = null;
  _downLocal = null;
  _downWindow = null;
  if (!enabled || !Platform.isWindows) return;
  final x = _screenX();
  final y = _screenY();
  final cur =
      (x == null || y == null) ? null : Offset(x.toDouble(), y.toDouble());
  try {
    final pos = await windowManager.getPosition();
    if (gen != _armGen) return; // 期间又按下/松开了，本次作废
    _downCursor = cur;
    _downLocal = local;
    _downWindow = pos;
    _dragArmed = true;
  } catch (_) {
    _dragArmed = false;
  }
}

int _armGen = 0;

bool _dragArmed = false;
bool _dragStarted = false;
bool _nativeTried = false;
Offset? _downCursor;
Offset? _downLocal;
Offset? _downWindow;

/// 移动：[local] 传当前指针的窗口内坐标，用于判阈值。
///
/// 超过 6px 才算拖动（避免单击带歪窗口）。先请系统接管（原生拖动），
/// 抛异常再退回手动 setPosition 跟手。
Future<void> updateWindowDrag({Offset? local}) async {
  if (!_dragArmed || _dragStarted) return;
  final d0 = _downLocal;
  final cur = local;
  if (d0 != null && cur != null) {
    final ddx = cur.dx - d0.dx;
    final ddy = cur.dy - d0.dy;
    if (ddx * ddx + ddy * ddy < 36) return;
  } else if (_downCursor == null) {
    return;
  }
  _dragStarted = true;
  if (!_nativeTried) {
    _nativeTried = true;
    try {
      await windowManager.startDragging();
      return;
    } catch (_) {
      // 落回手动跟手
    }
  }
  final x = _screenX();
  final y = _screenY();
  final d = _downCursor;
  final w0 = _downWindow;
  if (x == null || y == null || d == null || w0 == null) return;
  final dpr = WidgetsBinding
          .instance.platformDispatcher.implicitView?.devicePixelRatio ??
      1.0;
  _busy = true;
  try {
    await windowManager.setPosition(
        Offset(w0.dx + (x - d.dx) / dpr, w0.dy + (y - d.dy) / dpr),
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
  _nativeTried = false;
  _downCursor = null;
  _downLocal = null;
  _downWindow = null;
}
