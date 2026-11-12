import 'package:flutter/widgets.dart';

import 'device_profile.dart';

/// 尺寸/间距 token：三档设备基准（dp）。
///
/// 数值定稿见《重点模块详设》2.3。组件内禁止写尺寸字面量，
/// 一律 AppDensity.of(context).xxx 取值。
/// 用户字号滑块（0.85–1.30）通过 [userScale] 作用于带标签按钮等
/// 文字驱动尺寸；纯 dp 尺寸（台标、面板高）不随滑块缩放。
class AppDensity {
  const AppDensity({
    required this.panelHeight,
    required this.panelPaddingH,
    required this.logoSize,
    required this.logoGap,
    required this.buttonSize,
    required this.intraGroupGap,
    required this.interGroupGap,
    required this.useDividers,
    required this.listRowHeight,
    required this.infoActionMinGap,
    required this.modalRadius,
  });

  /// 底部面板总高
  final double panelHeight;

  /// 面板左右内边距（台标离屏幕左缘）
  final double panelPaddingH;

  /// 台标尺寸 / 台标→文字距
  final double logoSize;
  final double logoGap;

  /// ghost 按钮直径（普通钮；主控钮 ×1.2、TV 焦点态 ×1.05 在组件内固定倍率）
  final double buttonSize;

  /// 组内按钮距 / 组间距
  final double intraGroupGap;
  final double interGroupGap;

  /// 分组竖线：Windows/电视有，手机无（5 钮画线显碎）
  final bool useDividers;

  /// 频道列表行高
  final double listRowHeight;

  /// 底部面板信息区↔操作区最小距（中间弹性 Spacer）
  final double infoActionMinGap;

  /// 模态弹层圆角
  final double modalRadius;

  static const AppDensity _tv = AppDensity(
    panelHeight: 78, panelPaddingH: 20,
    logoSize: 44, logoGap: 14,
    buttonSize: 44, intraGroupGap: 10, interGroupGap: 28,
    useDividers: true,
    listRowHeight: 62,
    infoActionMinGap: 40,
    modalRadius: 16,
  );

  static const AppDensity _desktop = AppDensity(
    panelHeight: 66, panelPaddingH: 16,
    logoSize: 38, logoGap: 12,
    buttonSize: 38, intraGroupGap: 8, interGroupGap: 28,
    useDividers: true,
    listRowHeight: 50,
    infoActionMinGap: 32,
    modalRadius: 14,
  );

  static const AppDensity _mobile = AppDensity(
    panelHeight: 54, panelPaddingH: 12,
    logoSize: 32, logoGap: 10,
    buttonSize: 35, intraGroupGap: 8, interGroupGap: 24,
    useDividers: false,
    listRowHeight: 41,
    infoActionMinGap: 24,
    modalRadius: 12,
  );

  static AppDensity of(BuildContext context) {
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

/// 设备档 + 用户滑块的注入点：挂在 MaterialApp.builder 内，
/// 位于 MediaQuery(文字缩放) 之下。
///
/// 用法：builder 里用 [DeviceProfileScopeData] 包裹 child，任何组件通过
/// DeviceProfileScope.of(context) 拿到当前档位。
class DeviceProfileScope extends InheritedWidget {
  const DeviceProfileScope({
    super.key,
    required this.data,
    required super.child,
  });

  final DeviceProfileScopeData data;

  static DeviceProfileScopeData of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<DeviceProfileScope>();
    assert(scope != null, 'DeviceProfileScope 未挂载：必须包在 MaterialApp.builder 内');
    return scope!.data;
  }

  /// 当前设备档
  static DeviceProfile profileOf(BuildContext context) => of(context).profile;

  /// 用户滑块系数（0.85–1.30），作用于文字驱动尺寸
  static double scaleOf(BuildContext context) => of(context).userScale;

  @override
  bool updateShouldNotify(DeviceProfileScope oldWidget) =>
      oldWidget.data != data;
}

class DeviceProfileScopeData {
  const DeviceProfileScopeData({required this.profile, required this.userScale});

  final DeviceProfile profile;
  final double userScale;

  @override
  bool operator ==(Object other) =>
      other is DeviceProfileScopeData &&
      other.profile == profile &&
      other.userScale == userScale;

  @override
  int get hashCode => Object.hash(profile, userScale);
}
