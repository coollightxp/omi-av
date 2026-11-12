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
        iconPath: 'assets/tray/omi_tray.ico',
        toolTip: '$_kAppTitle · 左键恢复窗口',
      );
      await _buildMenu();
      await _tray.setContextMenu(_menu);
      _tray.registerSystemTrayEventHandler((eventName) {
        if (eventName == kSystemTrayEventClick) {
          // 左键：后台播放恢复（摸鱼中也恢复：托盘是唯一入口）
          if (_fishMode) {
            _fishMode = false;
            updateMenu(fishMode: false);
            onExitFish?.call();
          }
          onShowWindow?.call();
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
        onClicked: (_) async {
          _fishMode = !_fishMode;
          await updateMenu(fishMode: _fishMode);
          if (_fishMode) {
            // 摸鱼动作本体在 controller（静音 + 隐藏窗口）
            onEnterFish?.call();
          } else {
            onExitFish?.call();
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
