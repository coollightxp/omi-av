import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../services/player_controller.dart';

/// 定时关闭卡片 —— **纯视觉组件**。
///
/// 按键一个都不处理！这是与退出卡片（`_handleExitDialogKey`）/ 关机确认
/// 卡片（`_handleShutdownDialogKey`）完全相同的模式：按键逻辑全部写在
/// 播放页（player_screen 的 `_handleSleepCardKey`），行列焦点、选中动作
/// 都是播放页的成员变量，卡片只负责把数据画出来。
///
/// 之所以推倒重做：以前把按键处理挂在弹窗自己身上（HardwareKeyboard
/// 注册、根部 Focus.onKeyEvent、播放页 sink 转发——三条通道轮换着试了
/// 三个版本），用户实测这台机器上遥控器/键盘始终一个键都收不到。而
/// 退出卡片、关机卡片（按键在播放页处理）一直是好的。
///
/// [rows] 的行结构（与 `_handleSleepCardKey` 一一对应）：
/// 0 = 到点动作（左右即改选中） / 1 = 倒计时（OK 生效并关闭） /
/// 2 = 固定时刻（OK 进时间选择器） / 3 = 取消定时（可省略）
class SleepCardItem {
  final String label;

  /// 常亮高亮（当前选中的动作）；焦点白框由播放页的 row/col 决定
  final bool selected;
  const SleepCardItem(this.label, {this.selected = false});
}

/// 一次定时设置的结果：[at] 为 null 表示取消定时。
class SleepPick {
  const SleepPick(this.at, this.action);

  final DateTime? at;
  final SleepAction action;
}

/// 今天/明天最近的那个 HH:mm（凌晨选 23:30 就是明晚）
DateTime nextSleepAt(int hour, int minute) {
  final now = DateTime.now();
  var t = DateTime(now.year, now.month, now.day, hour, minute);
  if (!t.isAfter(now)) t = t.add(const Duration(days: 1));
  return t;
}

String sleepHhmm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String sleepFmtRemain(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final sec = d.inSeconds % 60;
  if (h > 0) {
    return '$h:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }
  return '$m:${sec.toString().padLeft(2, '0')}';
}

Widget buildSleepTimerCard({
  required List<List<SleepCardItem>> rows,
  required int row,
  required int col,
  String? remainText,
  required String atText,
  /// 鼠标点击（Windows/Linux 桌面）：点哪一项就把它当成「选中 + OK」，
  /// 语义与遥控器完全一致（动作行只改选中、倒计时立即生效、设置…进时间
  /// 选择器、取消定时直接清除）。传 null 时整张卡片不可点。
  void Function(int row, int col)? onTap,
  /// 临时诊断文字（v2.1.37）：显示两条按键通道各收到几个键、最近一个是什么。
  /// 确认遥控器在这张卡片上恢复正常后删除。
  String? debugText,
}) {
  Widget chip(SleepCardItem item, bool focused, int r, int c) {
    final selected = item.selected;
    final body = Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: focused
            ? AppColors.accent.withValues(alpha: 0.22)
            : selected
                ? AppColors.accent.withValues(alpha: 0.18)
                : Colors.transparent,
        border: Border.all(
          color: focused
              ? Colors.white
              : (selected ? AppColors.accent : AppColors.stroke),
          width: focused ? 2 : 1,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(item.label,
          style: TextStyle(
              color: selected || focused
                  ? AppColors.accent
                  : AppColors.textPrimary,
              fontSize: 13,
              fontWeight: focused ? FontWeight.w600 : FontWeight.normal)),
    );
    if (onTap == null) return body;
    // 点击区域用 opaque，卡片底色是透明的，不加这一条点到文字间隙会漏
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onTap(r, c),
        child: body,
      ),
    );
  }

  // 行与视觉区块的对应关系见类注释；行数可变（关机项/取消行可省略）
  final actionRow = rows.isNotEmpty ? rows[0] : const <SleepCardItem>[];
  final timerRow = rows.length > 1 ? rows[1] : const <SleepCardItem>[];
  final atRow = rows.length > 2 ? rows[2] : const <SleepCardItem>[];

  return AlertDialog(
    backgroundColor: AppColors.overlay,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: const BorderSide(color: AppColors.stroke),
    ),
    title: const Text('定时关闭',
        style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
    content: SizedBox(
      width: 340,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (remainText != null)
              Text(remainText,
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 12.5)),
            const SizedBox(height: 10),
            Wrap(
                spacing: 6,
                runSpacing: 5,
                children: [
                  for (var i = 0; i < actionRow.length; i++)
                    chip(actionRow[i], row == 0 && col == i, 0, i),
                ]),
            // 三趟之间留出明显段落：以前标签贴着上一排 chip，看着像
            // 同一组；用户要求「倒计时 / 23:30 那行 / 底部说明」都拉开
            const SizedBox(height: 16),
            const Text('倒计时',
                style:
                    TextStyle(color: AppColors.textSecondary, fontSize: 11.5)),
            const SizedBox(height: 7),
            Wrap(
                spacing: 6,
                runSpacing: 5,
                children: [
                  for (var i = 0; i < timerRow.length; i++)
                    chip(timerRow[i], row == 1 && col == i, 1, i),
                ]),
            const SizedBox(height: 16),
            const Text('固定时刻（点「设置」选几点，今天已过算明天）',
                style:
                    TextStyle(color: AppColors.textSecondary, fontSize: 11.5)),
            const SizedBox(height: 8),
            Row(
              children: [
                // 大号时间本身也可点：鼠标用户的直觉是「点时间改时间」
                MouseRegion(
                  cursor: onTap == null
                      ? MouseCursor.defer
                      : SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onTap == null ? null : () => onTap(2, 0),
                    child: Text(atText,
                        style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
                const SizedBox(width: 12),
                for (var i = 0; i < atRow.length; i++)
                  chip(atRow[i], row == 2 && col == i, 2, i),
              ],
            ),
            if (rows.length > 3) ...[
              const SizedBox(height: 10),
              chip(rows[3][0], row == 3 && col == 0, 3, 0),
            ],
            const SizedBox(height: 14),
            const Text('上下换一行 · 左右换一项 · OK 确定 · 返回退出',
                style:
                    TextStyle(color: AppColors.textTertiary, fontSize: 11)),
            if (debugText != null) ...[
              const SizedBox(height: 8),
              Text(debugText,
                  style: const TextStyle(
                      color: AppColors.success, fontSize: 10.5)),
            ],
          ],
        ),
      ),
    ),
  );
}
