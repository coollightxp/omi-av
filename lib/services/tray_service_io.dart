import 'dart:io';

import 'package:system_tray/system_tray.dart';

/// Windows 系统托盘（后台播放 / 摸鱼模式的容器）。
///
/// - 左键托盘图标：显示主窗口（后台播放恢复）
/// - 右键：菜单（显示主窗口 / 摸鱼模式 / 退出）
/// - 摸鱼模式：静音 + 隐藏窗口，再点一次恢复（音量状态还原）
///
/// 仅 Windows 实装；macOS/Linux 调用一律 no-op（Linux 依赖
/// libayatana-appindicator，装机率低，需要时再放开）。
class TrayService {
  TrayService._();

  static final TrayService instance = TrayService._();

  static const _kAppTitle = '欧米直播';

  final SystemTray _tray = SystemTray();
  final Menu _menu = Menu();
  bool _inited = false;
  bool _fishMode = false;

  /// 摸鱼模式开关（PlayerController 读取/同步）
  bool get fishMode => _fishMode;

  /// 托盘是否真的建起来了。图标建失败（资源路径/系统策略）时为 false：
  /// 调用方据此不要隐藏窗口，否则用户没有任何入口能把窗口找回来
  static bool get ready => instance._inited;

  /// 托盘图标绝对路径。
  ///
  /// system_tray 在 Windows 上走 Shell_NotifyIcon，图标要给**磁盘上真实
  /// 存在的文件**；Flutter 把 assets 打进 `data/flutter_assets/`，用
  /// 相对路径 `assets/tray/xxx.ico` 在装机目录下根本不存在，
  /// initSystemTray 抛异常被静默吞掉 —— 表现就是「托盘图标不出现」，
  /// 关闭到托盘/摸鱼模式一点就找不回窗口。这里按打包布局找绝对路径
  static String _resolveIcon() {
    final sep = Platform.pathSeparator;
    String exeDir;
    try {
      exeDir = File(Platform.resolvedExecutable).parent.path;
    } catch (_) {
      exeDir = '';
    }
    final candidates = <String>[
      if (exeDir.isNotEmpty)
        '$exeDir${sep}data${sep}flutter_assets${sep}assets${sep}tray${sep}omi_tray.ico',
      if (exeDir.isNotEmpty)
        '$exeDir${sep}assets${sep}tray${sep}omi_tray.ico',
      'assets/tray/omi_tray.ico',
    ];
    for (final c in candidates) {
      try {
        if (File(c).existsSync()) return c;
      } catch (_) {}
    }
    return 'assets/tray/omi_tray.ico';
  }

  /// ✕ 关闭按钮是否最小化到托盘（controller 同步；WindowListener 读取）
  static bool closeToTray = false;

  /// 摸鱼恢复回调（controller 注入：还原音量状态）
  static void Function()? onExitFish;

  /// 托盘「退出」回调（真正销毁窗口）
  static Future<void> Function()? onQuit;

  /// 显示主窗口回调
  static Future<void> Function()? onShowWindow;

  /// 初始化托盘（重复调用安全；仅 Windows 生效）
  static Future<void> ensure() async {
    if (Platform.isWindows) await instance._ensure();
  }

  Future<void> _ensure() async {
    if (_inited) return;
    _inited = true;
    try {
      await _tray.initSystemTray(
        title: _kAppTitle,
        iconPath: _resolveIcon(),
        toolTip: '$_kAppTitle · 左键恢复窗口',
      );
      await _buildMenu();
      await _tray.setContextMenu(_menu);
      _tray.registerSystemTrayEventHandler((eventName) {
        if (eventName == kSystemTrayEventClick) {
          // 左键：摸鱼中就退出摸鱼（含还原静音、显示窗口），否则只显示窗口。
          // 状态一律由 controller 改，这里不能提前翻 _fishMode ——
          // controller 的 exitFishMode/enterFishMode 都以 fishMode 做重入
          // 守卫，先翻会让守卫直接 return，静音还原/隐藏动作整段跳过
          if (_fishMode) {
            onExitFish?.call();
          } else {
            onShowWindow?.call();
          }
        } else if (eventName == kSystemTrayEventRightClick) {
          _tray.popUpContextMenu();
        }
      });
    } catch (_) {
      // 托盘失败不影响主流程（如系统策略禁用托盘）
      _inited = false;
    }
  }

  Future<void> _buildMenu() async {
    await _menu.buildFrom([
      MenuItemLabel(label: '显示主窗口', onClicked: (_) => onShowWindow?.call()),
      MenuSeparator(),
      MenuItemLabel(
        label: _fishMode ? '退出摸鱼模式（恢复画面声音）' : '摸鱼模式（静音并隐藏窗口）',
        onClicked: (_) {
          // 同左键：只发意图，_fishMode 与菜单文案由 controller 写回
          // （它做完静音/隐藏动作后调 updateMenu）。这里先翻状态的话，
          // controller 的重入守卫会把整段动作吃掉
          if (_fishMode) {
            onExitFish?.call();
          } else {
            onEnterFish?.call();
          }
        },
      ),
      MenuSeparator(),
      MenuItemLabel(label: '退出', onClicked: (_) => onQuit?.call()),
    ]);
  }

  static void Function()? onEnterFish;

  /// 摸鱼状态变化后重建菜单文案
  static Future<void> updateMenu({required bool fishMode}) async {
    instance._fishMode = fishMode;
    if (!Platform.isWindows || !instance._inited) return;
    await instance._buildMenu();
    await instance._tray.setContextMenu(instance._menu);
  }

  static Future<void> dispose() async {
    if (!Platform.isWindows || !instance._inited) return;
    try {
      await instance._tray.destroy();
    } catch (_) {}
    instance._inited = false;
  }
}
