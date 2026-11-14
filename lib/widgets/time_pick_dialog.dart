import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';

/// 遥控器/键盘友好的时间选择卡片 —— **纯视觉组件**。
///
/// 与定时关闭卡片同一套模式（也即退出卡片/关机确认卡片的模式）：
/// 按键逻辑全部在播放页（`_handleTimePickKey`），时分值、当前列、
/// 按钮焦点都是播放页的成员变量，这里只画。
///
/// [col]：0 = 正在调小时，1 = 正在调分钟，2 = 在「确定 / 取消」按钮上。
/// [btn]：按钮行里选中的是哪一个（0 = 确定，1 = 取消）。
Widget buildRemoteTimePickerCard({
  required String title,
  required int hour,
  required int minute,
  required int col,
  required int btn,
}) {
  Widget column({
    required int value,
    required bool active,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 96,
          height: 32,
          child: Icon(
            Icons.keyboard_arrow_up,
            size: 26,
            color: active ? AppColors.accent : Colors.white38,
          ),
        ),
        Container(
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
        SizedBox(
          width: 96,
          height: 32,
          child: Icon(
            Icons.keyboard_arrow_down,
            size: 26,
            color: active ? AppColors.accent : Colors.white38,
          ),
        ),
      ],
    );
  }

  Widget actionButton(String label, int index) {
    final focused = col == 2 && btn == index;
    final primary = index == 0;
    return Container(
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
    );
  }

  return AlertDialog(
    backgroundColor: AppColors.overlay,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: const BorderSide(color: AppColors.stroke),
    ),
    title: Text(
      title,
      style: const TextStyle(color: AppColors.textPrimary, fontSize: 16),
    ),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            column(value: hour, active: col == 0),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                ':',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 34,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            column(value: minute, active: col == 1),
          ],
        ),
        const SizedBox(height: 10),
        const Text(
          '上下调数值 · 左右切时/分 · 分钟上再按右到「确定」',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            actionButton('取消', 1),
            const SizedBox(width: 8),
            actionButton('确定', 0),
          ],
        ),
      ],
    ),
  );
}
