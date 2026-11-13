import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'services/auto_launch.dart';
import 'services/exit_guard.dart';
import 'services/media_capture_service.dart';
import 'services/tray_service.dart';
import 'services/web_env.dart';

/// 窗口关闭拦截：设置开了「✕ 最小化到托盘」时隐藏窗口继续播放，
/// 托盘图标左键恢复；否则交给 [ExitGuard] 走统一的有序退出
/// （先销毁网页控件/WebView2 环境，再快速结束进程）。
class _OmiWindowListener extends WindowListener {
  @override
  void onWindowClose() async {
    if (TrayService.closeToTray) {
      await windowManager.hide();
    } else {
      await ExitGuard.quit();
    }
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 注意：不能让 SharedPreferences 失败阻塞 runApp——平台通道一失败
  // main 直接死掉就是永久白屏（安卓实测 NoSuchMethodError 时整机白屏
  // 进不去）。失败时降级默认值，保证 App 一定能起来。
  var launchAtStartup = false;
  var alwaysOnTop = true;
  var webEnabled = true;
  var prefsOk = false;
  try {
    final prefs = await SharedPreferences.getInstance();
    launchAtStartup = prefs.getBool('settings_launch_at_startup') ?? false;
    alwaysOnTop = prefs.getBool('settings_always_on_top') ?? true;
    webEnabled = prefs.getBool('settings_web_enabled') ?? true;
    prefsOk = true;
  } catch (e) {
    debugPrint('SharedPreferences load failed, using defaults: $e');
  }

  // 仅在「网页直播支持」开启时才清理缓存并创建 WebView2 运行时环境。
  // 关闭时不调用、不创建，避免不支持 WebView2 的系统（如精简版
  // Windows 7/8、缺运行时的 Win10）在启动或退出时崩溃
  if (webEnabled) {
    // 启动前清理 WebView2 缓存，避免旧缓存导致网页频道加载慢/卡旧画面
    cleanWebView2Cache();
    // 创建自定义 WebView2 环境，禁用磁盘缓存 + 允许无手势自动播放
    await initWebViewEnvironment();
  }

  // 安卓手机：强制横屏（直播/电视场景，竖屏会留黑边）
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  final desktop = MediaCaptureService.isDesktop;
  if (desktop) {
    await windowManager.ensureInitialized();
    // 关闭拦截统一在这处理（托盘设置见 设置→系统）
    windowManager.addListener(_OmiWindowListener());

    final launchAtStartupSynced = launchAtStartup;
    if (prefsOk) {
      // 与系统开机启动项保持同步（配置加载失败时跳过，避免误关用户的自启动）
      await setAutoLaunchEnabled(launchAtStartupSynced);
    }
    // 注意：「启动全屏」不在这里执行——在窗口显示瞬间调用 setFullScreen
    // 会导致窗口尺寸错误（白屏方块+黑边、有声音无画面）。
    // 改由播放器界面首帧布局稳定后延迟执行（applyStartupFullscreen）。

    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        title: '欧米视听',
        center: true,
        titleBarStyle: TitleBarStyle.hidden,
        // 原生窗口背景刷成黑色：默认白底会在启动全屏的一瞬间闪白框
        backgroundColor: Colors.black,
      ),
      () async {
        // 窗口固定尺寸（1280×720）：不响应拖边缩放/最大化，
        // 防止面板变形、文字堆叠（小窗模式在控制器里同样锁死尺寸）
        await windowManager.setResizable(false);
        await windowManager.show();
        await windowManager.focus();
        // 窗口置顶（默认开）：避免被其它窗口抢焦点导致快捷键失灵；
        // 设置面板里可关闭
        final alwaysOnTopSynced = alwaysOnTop;
        if (alwaysOnTopSynced) {
          await windowManager.setAlwaysOnTop(true);
        }
        // 注意：不要在这里切换系统/窗口输入法——
        // Windows 默认未开启“每个应用窗口使用不同输入法”，
        // 任何键盘布局切换都会全局生效。快捷键改用硬件按键事件
        // （KeyDownEvent / WM_KEYDOWN）处理，中文输入法下同样有效，
        // 无需改变用户的输入法状态。
      },
    );
  }

  runApp(const OmiApp());
}
