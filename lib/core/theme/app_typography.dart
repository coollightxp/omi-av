import 'package:flutter/widgets.dart';

import 'app_density.dart';
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
    required this.listHeader,
    required this.listItem,
    required this.listSub,
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

  /// 列表标题（频道列表抽屉头、分类名）
  final double listHeader;

  /// 列表主行（频道名、EPG 节目名）
  final double listItem;

  /// 列表次行（频道号、节目时间、分区数量）
  final double listSub;

  /// 数值以 1.0.201 实测观感校准（面板大字 24/节目行 14.5/badge 13），
  /// 而非激进紧凑值：token 化的收益是集中可调 + 三档联动，
  /// 数值必须先贴近现状再谈优化，避免"改完不如原来"。
  ///
  /// 列表三档目前取同一组值（18/16/12.5）：列表是"密度优先"界面，
  /// 行高与字号是一对（见 AppDensity.listRowHeight），单改字号会把
  /// 一屏频道数改掉。要按设备差异化，只改这张表 + 对应行高即可。
  static const AppTypography _tv = AppTypography(
    title: 24, body: 17, caption: 14, osdNumber: 46, osdCaption: 15,
    listHeader: 18, listItem: 16, listSub: 12.5,
  );
  static const AppTypography _desktop = AppTypography(
    title: 22, body: 14.5, caption: 12.5, osdNumber: 42, osdCaption: 14,
    listHeader: 18, listItem: 16, listSub: 12.5,
  );
  static const AppTypography _mobile = AppTypography(
    title: 17, body: 12.5, caption: 11, osdNumber: 30, osdCaption: 12,
    listHeader: 18, listItem: 16, listSub: 12.5,
  );

  static AppTypography of(BuildContext context) {
    final profile = DeviceProfileScope.profileOf(context);
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
