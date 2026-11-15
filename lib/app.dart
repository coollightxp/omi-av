import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'core/theme/app_density.dart';
import 'core/theme/device_profile.dart';
import 'services/player_controller.dart';
import 'screens/player_screen.dart';

/// 各平台选用观感更清晰、圆润的系统无衬线字体：
/// Windows 用「Microsoft YaHei UI」（比默认回退的雅黑小字号更清晰），
/// Linux 用 Noto Sans CJK SC；macOS/iOS/Android 沿用系统默认
/// （SF Pro / 苹方 / Roboto，本身已经足够圆润）
String? get _platformFontFamily {
  if (kIsWeb) return null;
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
      return 'Microsoft YaHei UI';
    case TargetPlatform.linux:
      return 'Noto Sans CJK SC';
    default:
      return null;
  }
}

class OmiApp extends StatelessWidget {
  const OmiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => PlayerController(),
      child: const _OmiMaterialApp(),
    );
  }
}

/// MaterialApp 只构建一次。
///
/// 旧实现把 `Consumer<PlayerController>` 套在 MaterialApp 外面，于是
/// **任何** notifyListeners（播放进度、缓冲、切台、改一个设置）都会重建
/// MaterialApp → 重建 ThemeData → 全树主题/媒体查询变化 → 播放层跟着
/// 重排，表现就是"正在播的时候点设置里的开关卡一下"。
/// 现在设置走 [PlayerController.settingsNotifier]、设备档位走
/// [PlayerController.tvModeNotifier]，只有它们变化时才局部重建
/// MediaQuery 包装层，导航树与播放树都不动。
class _OmiMaterialApp extends StatelessWidget {
  const _OmiMaterialApp();

  @override
  Widget build(BuildContext context) {
    final controller = context.read<PlayerController>();
    return MaterialApp(
      title: '欧米视听',
      debugShowCheckedModeBanner: false,
      // 中文本地化：输入框长按菜单（粘贴/复制）等系统文案用中文，
      // 否则 Android/Windows 上长按输入框弹出的都是英文
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      locale: const Locale('zh', 'CN'),
      // 全局统一字体族须在 ThemeData 构造函数传入（copyWith 无此参数）
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        fontFamily: _platformFontFamily,
      ).copyWith(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blueAccent,
          brightness: Brightness.dark,
        ),
      ),
      // 全局按键映射：电视遥控器 / 手柄的 OK 键发的是 select（不是
      // Enter），而 Material 的按钮、开关、列表项只认 Enter/Space，
      // 不映射的话遥控器按 OK 毫无反应；小键盘回车同理。
      builder: (context, child) => Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
        },
        child: ListenableBuilder(
          listenable: Listenable.merge([
            controller.settingsNotifier,
            controller.tvModeNotifier,
          ]),
          child: child,
          builder: (context, child) {
            final mq = MediaQuery.of(context);
            final settings = controller.settingsNotifier.value;
            // 全局文字缩放只反映用户在设置里的「界面缩放」：
            //   自动 → 大屏按物理宽度放大（TV 1080p=1.0/2K≈1.33/4K=2.0/8K=3.0），
            //          手机/小平板不放大（1.0）；
            //   手动 → 用户选定值（0.8~3.0）
            // 设备形态（手机面板整体缩小）不在这里做，否则会与各面板的
            // ScaledPanel Transform 缩放叠加（面板里文字被缩两次，变得极小）。
            final shortest = mq.size.shortestSide;
            final isAndroid =
                !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
            final isSmallAndroid = isAndroid && shortest < 720;
            double scale;
            if (settings.uiScaleAuto) {
              if (isSmallAndroid) {
                scale = 1.0;
              } else {
                final physicalW = mq.size.width * mq.devicePixelRatio;
                scale = (physicalW / 1920.0).clamp(1.0, 3.0);
              }
            } else {
              scale = settings.uiScale.clamp(0.8, 3.0);
            }
            // 设备档位注入：桌面=desktop；安卓按 TV 检测结果分 tv/mobile；
            // Web 无 TV 场景按 desktop。token 体系（AppDensity/AppTypography）
            // 经此 InheritedWidget 对全树生效
            final isTv = controller.tvModeNotifier.value;
            final profile = kIsWeb
                ? DeviceProfile.desktop
                : (defaultTargetPlatform == TargetPlatform.android
                    ? (isTv ? DeviceProfile.tv : DeviceProfile.mobile)
                    : DeviceProfile.desktop);
            return MediaQuery(
              data: mq.copyWith(textScaler: TextScaler.linear(scale)),
              child: DeviceProfileScope(
                data: DeviceProfileScopeData(profile: profile, userScale: 1.0),
                child: child!,
              ),
            );
          },
        ),
      ),
      home: const PlayerScreen(),
    );
  }
}
