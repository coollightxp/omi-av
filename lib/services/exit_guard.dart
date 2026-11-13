import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import 'tray_service.dart';
import 'win_hotkeys.dart';

/// 统一退出流程（Windows 桌面端）。
///
/// 背景：退出时崩溃（0xc0000005 / "已停止工作"）的根因是**析构顺序**——
/// WebView2 平台视图随引擎一起拆，COM 释放与 Flutter 引擎关停并发；
/// 有时还会连带 mpv 的解码线程。正确顺序是：
///
///   ① 先让播放页退出网页态（WebView 平台视图销毁）
///   ② 释放 WebView2 环境与宿主子进程
///   ③ 请求 runner 摘钩子/恢复光标后快速结束进程（跳过会崩的析构链）
///   ④ 最后才 destroy 窗口
///
/// 之前 main.dart 的窗口监听直接 `destroy()`，与播放页里那套顺序流程
/// 抢着执行，等于把最危险的那一步提前了——退出崩溃就是这么回来的。
/// 现在所有退出入口（标题栏 ✕、托盘「退出」、快捷键）都走这里。
class ExitGuard {
  ExitGuard._();

  /// 由播放页注册：销毁网页控件 / 释放 WebView2 环境。
  /// 未注册（例如还在启动页）时直接跳过。
  static Future<void> Function()? prepare;

  static bool _exiting = false;

  /// 是否已在退出流程中（防重入：连点 ✕ / 托盘与快捷键同时触发）
  static bool get exiting => _exiting;

  /// 执行一次完整的有序退出。
  static Future<void> quit() async {
    if (_exiting) return;
    _exiting = true;
    try {
      final p = prepare;
      if (p != null) {
        await p().timeout(const Duration(seconds: 6));
      }
    } catch (e) {
      debugPrint('ExitGuard prepare failed: $e');
    }
    // 先摘托盘图标：下面 runner 一发「快速结束进程」，system_tray 就
    // 没机会走 destroy 了——通知区会残留一个僵尸图标（点一下才消失）
    try {
      await TrayService.dispose().timeout(const Duration(seconds: 2));
    } catch (_) {}
    // runner 侧摘低级键盘钩子、恢复系统光标；旧 runner 无此指令也无妨
    unawaited(WinHotkeys.quitApp());
    // 给 WebView2 子进程与 mpv 线程一点收尾时间（实测 <500ms 够用）
    await Future<void>.delayed(const Duration(milliseconds: 500));
    try {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (_) {
      // 窗口已销毁/管理器不可用：直接静默结束，避免二次弹窗
    }
  }
}
