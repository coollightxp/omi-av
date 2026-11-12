import 'package:flutter/widgets.dart';

import 'device_profile.dart';

/// 语义字号 token：三档设备基准（sp）。
///
/// 数值定稿见《重点模块详设》2.3。组件内禁止写 fontSize 字面量，
/// 一律 AppTypography.of(context).xxx 取值；OSD 专用槽保证闪现文字
/// 比普通标题大一档且不混用面板字号。
class AppTypography {
  const AppTypography({
    required this.title,
    required this.body,
    required this.caption,
    required this.osdNumber,
    required this.osdCaption,
  });

  /// 频道名/标题
  final double title;

  /// 正文/节目名
  final double body;

  /// 辅助/技术信息
  final double caption;

  /// OSD 频道号大数字（比 title 大一档，闪现注意力焦点）
  final double osdNumber;

  /// OSD 辅助行
  final double osdCaption;

  static const AppTypography _tv = AppTypography(
    title: 18, body: 15, caption: 13, osdNumber: 26, osdCaption: 14,
  );
  static const AppTypography _desktop = AppTypography(
    title: 15, body: 13, caption: 11, osdNumber: 20, osdCaption: 12,
  );
  static const AppTypography _mobile = AppTypography(
    title: 13, body: 10.5, caption: 10.5, osdNumber: 17, osdCaption: 10.5,
  );

  static AppTypography of(BuildContext context) {
    final profile = DeviceProfileScope.of(context);
    switch (profile) {
      case DeviceProfile.tv:
        return _tv;
      case DeviceProfile.desktop:
        return _desktop;
      case DeviceProfile.mobile:
        return _mobile;
    }
  }
}
