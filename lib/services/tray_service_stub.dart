/// 托盘服务占位实现（Web / 无托盘平台）：全部 no-op
class TrayService {
  TrayService._();

  static final TrayService instance = TrayService._();

  /// ✕ 关闭按钮是否最小化到托盘（Windows 实装；占位恒 false）
  static bool closeToTray = false;

  static void Function()? onShowWindow;
  static void Function()? onEnterFish;
  static void Function()? onExitFish;
  static Future<void> Function()? onQuit;

  /// 摸鱼模式开关（Windows 实装；占位恒 false）
  bool get fishMode => false;

  static Future<void> ensure() async {}

  static Future<void> updateMenu({required bool fishMode}) async {}

  static Future<void> dispose() async {}
}
