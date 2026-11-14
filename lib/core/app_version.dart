/// 应用版本号（显示在退出卡片等处）。
///
/// 以前这里是 `player_screen.dart` 里一个手写常量，写着写着就忘了改——
/// 用户装了 2.1.27，退出卡片还印着 1.0.201。现在集中到这里，发版时
/// 由发布脚本按 pubspec 自动改写（见 tools 里的提交脚本）。
///
/// 用 const 而不是 package_info：桌面/安卓都免掉一次平台通道往返，
/// 版本号在编译期就定死，不会出现"UI 显示比实际包旧"的另一种错法。
class AppVersion {
  AppVersion._();

  /// 与 `pubspec.yaml` 的 `version:` 前半段严格一致
  static const String value = '2.1.34';
}
