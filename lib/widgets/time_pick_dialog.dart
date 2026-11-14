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
/// - **左右** = 在「时 / 分」两列之间切换
/// - **OK / 确定** = 确认；**返回 / Esc** = 取消
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

  /// 0 = 正在调小时，1 = 正在调分钟
  int _col = 0;

  final FocusNode _focus = FocusNode(debugLabel: 'remoteTimePicker');

  @override
  void initState() {
    super.initState();
    _openCount++;
  }

  @override
  void dispose() {
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

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = event.logicalKey;
    // 上 = 加，下 = 减（与滚轮/数字选择器的直觉一致）
    if (k == LogicalKeyboardKey.arrowUp) {
      _step(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      _step(-1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      setState(() => _col = 0);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      setState(() => _col = 1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.gameButtonA ||
        k == LogicalKeyboardKey.space) {
      _confirm();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape ||
        k == LogicalKeyboardKey.goBack ||
        k == LogicalKeyboardKey.browserBack) {
      Navigator.pop(context);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
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
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
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
              '上下调数值 · 左右切时/分 · OK 确定',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: _confirm,
            child: const Text('确定', style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
    );
  }
}
