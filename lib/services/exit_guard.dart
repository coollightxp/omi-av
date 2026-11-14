import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import 'tray_service.dart';
import 'win_error_mode.dart';
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

  /// 退出提示可见性：进入退出流程立即点亮。
  /// 首屏（空闲待选台画面）监听它，把「请选择频道开始观看」
  /// 换成「正在退出…」，避免退出瞬间闪回选台文案让人以为没退掉
  static final ValueNotifier<bool> exitVisible = ValueNotifier(false);

  /// 执行一次完整的有序退出。
  static Future<void> quit() async {
    if (_exiting) return;
    _exiting = true;
    exitVisible.value = true;
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
    // Windows：到这里一切该保存的都已落盘，直接 ExitProcess 结束进程。
    // 不再走 destroy + 引擎/CRT 拆解——用户实测退出时仍会偶发
    // 「omi.exe - 快速异常检测失败」弹框（某个原生收尾线程在析构
    // 中途 abort，SetErrorMode 压不住），优雅关闭治不了随机性，
    // 只能跳过析构链。窗口随进程一起消失，托盘图标上面已摘掉。
    if (Platform.isWindows) {
      try {
        hardExitProcess();
        // hardExit 正常不返回；走到这里说明调用失败，落回 destroy
      } catch (_) {}
    }
    try {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (_) {
      // 窗口已销毁/管理器不可用：直接静默结束，避免二次弹窗
    }
  }
}
