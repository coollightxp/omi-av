import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'focus_region.dart';
import 'safe_focus.dart';

typedef RegionKeyHandler = KeyEventResult Function(KeyEvent event);

/// 焦点协调器：全 App 唯一的硬件按键分发点与焦点主权持有者。
///
/// 设计（见《重点模块详设-焦点协调器与密度Token.md》）：
/// - 内部维护 Region 栈；按键只分发给栈顶区域，下层区域在栈顶存在期间
///   收不到任何按键——"焦点穿透"（同一按键被两处处理）在结构上不可能发生。
/// - push 时为被覆盖的层存档当前焦点节点；pop 时精确恢复（不是 reset 到
///   列表第一项）。
/// - 各区域通过 [registerHandler] 注册自己的按键处理器；协调器不关心
///   具体业务（换台/移焦点），只负责路由与声明 handled。
class FocusCoordinator extends ChangeNotifier {
  FocusCoordinator._();
  static final FocusCoordinator instance = FocusCoordinator._();

  final List<FocusRegion> _stack = [FocusRegion.player];

  /// 每层被覆盖前的焦点存档：region -> 打开下一层时的 primaryFocus
  final Map<FocusRegion, FocusNode?> _archive = {};

  /// 各区域的按键处理器（区域未注册 = 收到按键一律 ignored）
  final Map<FocusRegion, RegionKeyHandler> _handlers = {};

  FocusRegion get current => _stack.last;

  bool get isOnPlayer => _stack.length == 1;

  // ==================== 区域生命周期 ====================

  /// 面板打开：压栈并把焦点交给新面板。
  ///
  /// [initialFocus] 为空时仅压栈不移动焦点（适用于纯输入态切换如
  /// numberInput，焦点仍留在原处但按键由 numberInput 分支接管）。
  void push(FocusRegion region, {FocusNode? initialFocus}) {
    assert(region != FocusRegion.player, 'player 是栈底，不可 push');
    // 已在栈顶则不重复压（防重复 push 导致双层同区）
    if (_stack.last == region) return;
    // 若该区域已在栈中更深位置，先静默移除旧记录（异常恢复路径）
    _stack.remove(region);
    _archive[_stack.last] = FocusManager.instance.primaryFocus;
    _stack.add(region);
    if (initialFocus != null) safeRequestFocus(initialFocus);
    notifyListeners();
  }

  /// 面板关闭：弹栈并恢复上一层存档的焦点。
  void pop() {
    assert(_stack.length > 1, 'player 是栈底，不可 pop');
    final closed = _stack.removeLast();
    _archive.remove(closed);
    final restore = _archive[_stack.last];
    if (restore != null) safeRequestFocus(restore);
    notifyListeners();
  }

  /// 关闭到指定层（弹栈直到栈顶为 [region]）；用于一次关掉多层叠加。
  void popTo(FocusRegion region) {
    while (_stack.length > 1 && _stack.last != region) {
      _stack.removeLast();
    }
    final restore = _archive[_stack.last];
    if (restore != null) safeRequestFocus(restore);
    notifyListeners();
  }

  // ==================== 按键处理 ====================

  /// 注册区域按键处理器（面板 init 时注册、dispose 时以 null 注销）。
  void registerHandler(FocusRegion region, RegionKeyHandler? handler) {
    if (handler == null) {
      _handlers.remove(region);
    } else {
      _handlers[region] = handler;
    }
  }

  /// 全 App 唯一按键入口：挂在最外层 FocusScope 的 onKeyEvent。
  ///
  /// 只处理按下事件（抬起忽略）；分发结果由区域处理器决定，
  /// 处理过的事件返回 handled 终止冒泡。
  KeyEventResult onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || event is KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final handler = _handlers[current];
    if (handler == null) return KeyEventResult.ignored;
    final result = handler(event);
    // 未挂载处理器的区域（窗口期）：短暂忽略，不冒泡给下层
    // ——下层此刻不应收到按键，这正是协调器存在的意义。
    return result;
  }
}
