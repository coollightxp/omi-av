import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme/app_colors.dart';

/// 遥控器/键盘友好的时间选择对话框。
///
/// 系统 `showTimePicker` 是「表盘拖拽 + 键盘数字输入」的设计：遥控器上
/// 没有数字键、也没法拖拽，用户只能干看着默认的 23:30 改不动
/// （实测反馈）。这里换成电视盒子式的两列数字：
///
/// - **上下** = 当前列 ±1（按住连发，遥控器长按自然加速）
/// - **左右** = 在「时 / 分」两列之间切换；**在分钟上再按右**出到
///   「确定 / 取消」这一排（用户实测要求：上下在数字里循环，只有
///   左右才能跳出去，否则出不来）
/// - **OK** = 数字区里=直接确定；按钮上=执行当前按钮
/// - **返回 / Esc** = 取消
/// - 鼠标：点数字列选中该列，点 ▲▼ 或直接点数字增减
///
/// 返回值语义与 `showTimePicker` 一致：取消返回 null。
Future<TimeOfDay?> showRemoteTimePicker(
  BuildContext context, {
  required TimeOfDay initial,
  String title = '选择时间',
}) {
  return showDialog<TimeOfDay>(
    context: context,
    barrierColor: AppColors.scrim,
    builder: (_) => _RemoteTimePickerDialog(initial: initial, title: title),
  );
}

/// 自绘时间选择器是否处于打开状态。
///
/// 播放页有一层「弹层统一收口」的全局按键处理：弹层打开时它会吞掉方向键、
/// 并把 OK 当成关闭弹层（Navigator.maybePop）。时间选择器要自己处理上下/
/// 左右/OK，必须让它放行，否则遥控器一按 OK 对话框就没了。
bool get remoteTimePickerOpen => _openCount > 0;
int _openCount = 0;

/// 按键接收器：打开期间由播放页的全局键盘 handler 转发（与定时关闭弹窗
/// 同一套），另外自己注册一份 HardwareKeyboard，三通道 + 60ms 去重。
bool Function(KeyEvent event)? timePickerKeySink;

class _RemoteTimePickerDialog extends StatefulWidget {
  const _RemoteTimePickerDialog({required this.initial, required this.title});

  final TimeOfDay initial;
  final String title;

  @override
  State<_RemoteTimePickerDialog> createState() =>
      _RemoteTimePickerDialogState();
}

class _RemoteTimePickerDialogState extends State<_RemoteTimePickerDialog> {
  late int _hour = widget.initial.hour;
  late int _minute = widget.initial.minute;

  /// 0 = 正在调小时，1 = 正在调分钟，2 = 在「确定 / 取消」按钮上
  int _col = 0;

  /// 按钮行里选中的是哪一个：0 = 确定，1 = 取消
  int _btn = 0;

  final FocusNode _focus = FocusNode(debugLabel: 'remoteTimePicker');

  /// 同键去重：两条通道都挂，只让第一个到达的执行一次
  int _lastKeyId = 0;
  int _lastKeyAt = 0;

  @override
  void initState() {
    super.initState();
    _openCount++;
    // 与定时关闭弹窗同一套三通道：播放页转发 + 弹窗根部 Focus +
    // 自己注册硬件键盘。_onHardwareKey 里 60ms 同键去重保证只执行一次
    timePickerKeySink = _onHardwareKey;
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
  }

  @override
  void dispose() {
    if (timePickerKeySink == _onHardwareKey) timePickerKeySink = null;
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _openCount--;
    _focus.dispose();
    super.dispose();
  }

  void _step(int delta) {
    setState(() {
      if (_col == 0) {
        _hour = (_hour + delta + 24) % 24;
      } else {
        _minute = (_minute + delta + 60) % 60;
      }
    });
  }

  void _confirm() =>
      Navigator.pop(context, TimeOfDay(hour: _hour, minute: _minute));

  /// 遥控器/键盘按键（HardwareKeyboard 通道）。
  /// 必须自己是栈顶弹窗才动手（上层不会再有弹窗，防御性保留）。
  bool _onHardwareKey(KeyEvent event) {
    if (!mounted) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    final k = event.logicalKey;
    // 与定时关闭弹窗同一套：硬件通道与焦点链双保险，同键 60ms 去重
    final now = DateTime.now().millisecondsSinceEpoch;
    if (k.keyId == _lastKeyId && now - _lastKeyAt < 60) return true;
    _lastKeyId = k.keyId;
    _lastKeyAt = now;
    // 上 = 加，下 = 减（与滚轮/数字选择器的直觉一致）。
    // 焦点在按钮行时，上下都退回分钟框——数字区里上下只循环调数值，
    // 要出到按钮只能走左右
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      if (_col == 2) {
        setState(() => _col = 1);
      } else {
        _step(k == LogicalKeyboardKey.arrowUp ? 1 : -1);
      }
      return true;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      setState(() {
        if (_col == 2) {
          _btn = 0;
        } else if (_col == 1) {
          _col = 0;
        }
      });
      return true;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      setState(() {
        if (_col == 0) {
          _col = 1;
        } else if (_col == 1) {
          // 分钟再往右 = 跳出数字区，落到「确定」
          _col = 2;
          _btn = 0;
        } else {
          _btn = 1;
        }
      });
      return true;
    }
    if (k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.gameButtonA ||
        k == LogicalKeyboardKey.space) {
      if (event is KeyDownEvent) {
        if (_col == 2 && _btn == 1) {
          Navigator.pop(context);
        } else {
          _confirm();
        }
      }
      return true;
    }
    if (k == LogicalKeyboardKey.escape ||
        k == LogicalKeyboardKey.goBack ||
        k == LogicalKeyboardKey.browserBack) {
      if (event is KeyDownEvent) Navigator.pop(context);
      return true;
    }
    return false;
  }

  /// 一列数字：▲ / 数字 / ▼。点击数字本身切换当前列
  Widget _column({
    required int value,
    required bool active,
    required VoidCallback onTapColumn,
    required VoidCallback onUp,
    required VoidCallback onDown,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _arrow(Icons.keyboard_arrow_up, active, onUp),
        GestureDetector(
          onTap: onTapColumn,
          child: Container(
            width: 96,
            height: 84,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active
                  ? AppColors.accent.withValues(alpha: 0.22)
                  : Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: active ? AppColors.accent : AppColors.stroke,
                width: active ? 2 : 1,
              ),
            ),
            child: Text(
              value.toString().padLeft(2, '0'),
              style: TextStyle(
                color: active ? Colors.white : AppColors.textPrimary,
                fontSize: 40,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
        _arrow(Icons.keyboard_arrow_down, active, onDown),
      ],
    );
  }

  Widget _arrow(IconData icon, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 96,
        height: 32,
        child: Icon(
          icon,
          size: 26,
          color: active ? AppColors.accent : Colors.white38,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 双通道保险：硬件通道 + 焦点链各挂一份，_onHardwareKey 里按
    // 「同键 60ms」去重，所以不会出现同一键执行两次（跳两格）
    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) => _onHardwareKey(e)
          ? KeyEventResult.handled
          : KeyEventResult.ignored,
      child: AlertDialog(
      backgroundColor: AppColors.overlay,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.stroke),
      ),
      title: Text(
        widget.title,
        style: const TextStyle(color: AppColors.textPrimary, fontSize: 16),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _column(
                value: _hour,
                active: _col == 0,
                onTapColumn: () => setState(() => _col = 0),
                onUp: () {
                  setState(() => _col = 0);
                  _step(1);
                },
                onDown: () {
                  setState(() => _col = 0);
                  _step(-1);
                },
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  ':',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 34,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _column(
                value: _minute,
                active: _col == 1,
                onTapColumn: () => setState(() => _col = 1),
                onUp: () {
                  setState(() => _col = 1);
                  _step(1);
                },
                onDown: () {
                  setState(() => _col = 1);
                  _step(-1);
                },
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            '上下调数值 · 左右切时/分 · 分钟上再按右到「确定」',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 14),
          // 确定 / 取消：只有从分钟框按右才出得来（用户定义的顺序），
          // 所以这两个按钮不进焦点树，焦点状态由 _col/_btn 自己画
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _actionButton('取消', 1, () => Navigator.pop(context)),
              const SizedBox(width: 8),
              _actionButton('确定', 0, _confirm),
            ],
          ),
        ],
      ),
      ),
    );
  }

  /// 按钮行的一个按钮：_col==2 且 _btn 命中时画白框（遥控器焦点）
  Widget _actionButton(String label, int index, VoidCallback onTap) {
    final focused = _col == 2 && _btn == index;
    final primary = index == 0;
    return GestureDetector(
      onTap: () {
        setState(() {
          _col = 2;
          _btn = index;
        });
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
        decoration: BoxDecoration(
          color: primary
              ? AppColors.accent.withValues(alpha: focused ? 0.30 : 0.18)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: focused
                ? Colors.white
                : (primary ? AppColors.accent : AppColors.stroke),
            width: focused ? 2 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: primary ? Colors.white : AppColors.textSecondary,
            fontSize: 13.5,
            fontWeight: primary ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}
