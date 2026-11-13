import 'package:flutter/material.dart';

/// 全 App 颜色 token（视觉现代化定稿：深蓝体系、单强调色、三级文字色）。
///
/// 纪律：组件里禁止出现 Colors.xxx 字面量，一律从 [AppColors] 取值。
class AppColors {
  AppColors._();

  // ==================== 基底与表面（四级层级，见方案 3.8） ====================

  /// 全局基底（页面背景）
  static const Color base = Color(0xFF0A0E17);

  /// 面板表面色：左右通高面板 / 底部等宽面板（半透明，深蓝体系）
  static const Color surface = Color(0xD91B2130); // 85% 不透明深蓝灰

  /// 模态弹层表面（退出卡片/设置中心/线路菜单）：比面板再亮一档
  static const Color overlay = Color(0xF0222838);

  /// 设置面板等"大块常驻弹层"用的不透明表面。
  ///
  /// `overlay` 带 6% 透明度，在 Windows 老显卡上做局部重绘时，内容变短
  /// （例如删掉一行源）后会露出一块没被绘制的区域，看起来是纯白空白。
  /// 常驻面板一律用这个不透明色，页面边缘的视觉差异几乎看不出来。
  static const Color overlaySolid = Color(0xFF222838);

  /// 表面描边：白色 15%，让面板在纯暗画面上立得住
  static const Color stroke = Color(0x26FFFFFF);

  /// 面板弹出时的全屏薄纱（25% 黑，面板永远坐在比它暗的底上）
  static const Color scrim = Color(0x40000000);

  // ==================== 文字三级 ====================

  /// 标题级：频道名/卡片主标题
  static const Color textPrimary = Color(0xFFF2F4F8);

  /// 正文级：节目名/列表正文
  static const Color textSecondary = Color(0xFFB8BECE);

  /// 辅助级：技术信息/时间戳
  static const Color textTertiary = Color(0xFF6E768C);

  // ==================== 强调色（全 App 唯一饱和色） ====================

  /// 强调色：仅用于播放/暂停主控钮、焦点描边、当前选中项
  static const Color accent = Color(0xFF3D7BD9);

  /// 焦点发光（TV 焦点态阴影色）
  static const Color focusGlow = Color(0x663D7BD9);

  // ==================== 状态色 ====================

  /// 直播中红点 / 错误
  static const Color live = Color(0xFFE5484D);

  /// 音频波形（电台 Now Playing / 底部「音频直播」徽章专用暖金）。
  /// 与电台舞台的暖黑底同源，是深蓝体系里唯一允许的暖色语义色。
  static const Color wave = Color(0xFFFFB35C);

  /// 成功/已连接
  static const Color success = Color(0xFF46A758);

  /// 禁用/置灰
  static const Color disabled = Color(0x55FFFFFF);

  // ==================== 分组竖线（面板内，白 13%） ====================

  static const Color divider = Color(0x21FFFFFF);
}
