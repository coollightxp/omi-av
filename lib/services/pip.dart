import 'package:flutter/services.dart';

/// 安卓原生桥：系统画中画（小窗）、退到后台听电视、
/// 通知栏音频卡片（含上一台/暂停/下一台/关闭）。
///
/// 原生实现由 CI 在 flutter create 生成 android/ 工程时注入
/// （MainActivity + MediaService：画中画、听电视退后台、
/// 通知栏/锁屏音频卡片；AndroidManifest 开启 supportsPictureInPicture /
/// 前台服务权限）。其他平台没有该通道，调用会抛
/// MissingPluginException，这里统一吞掉并返回 false。
const MethodChannel _channel = MethodChannel('omi/pip');

void Function(bool active)? _pipCb;
void Function(String cmd)? _audioCb;
bool _handlerInstalled = false;

void _ensureHandler() {
  if (_handlerInstalled) return;
  _handlerInstalled = true;
  _channel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'pip':
        _pipCb?.call(call.arguments == true);
        break;
      case 'audio':
        // 通知栏按钮：playpause / prev / next / stop / restore
        _audioCb?.call(call.arguments?.toString() ?? '');
        break;
    }
  });
}

/// 进入系统画中画；成功返回 true（Android 8.0+ 且 activity 在前台）
Future<bool> enterPip() async {
  try {
    return await _channel.invokeMethod<bool>('enter') ?? false;
  } catch (_) {
    return false;
  }
}

/// 退出画中画（恢复到全屏窗口）
Future<void> exitPip() async {
  try {
    await _channel.invokeMethod('exit');
  } catch (_) {}
}

/// 同步「切后台自动画中画」开关给原生：播放中按 Home/切到别的应用时
/// 自动进入画中画小窗（PlayerController 在播放状态变化时调用）。
/// Android 12+ 由 setAutoEnterEnabled 接管，8–11 走 onUserLeaveHint。
Future<void> setAutoPip(bool armed) async {
  try {
    await _channel.invokeMethod('setAutoPip', {'armed': armed});
  } catch (_) {}
}

/// 把应用退到后台但保持播放（听电视隐藏窗口）；成功返回 true
Future<bool> moveToBackground() async {
  try {
    return await _channel.invokeMethod<bool>('background') ?? false;
  } catch (_) {
    return false;
  }
}

/// 是否 Android TV / 电视盒子（Leanback 或电视系统特性）。
/// 电视端没有通知栏可操作，「听电视」必须始终留在信息卡片上。
Future<bool> isTvDevice() async {
  try {
    return await _channel.invokeMethod<bool>('isTv') ?? false;
  } catch (_) {
    return false;
  }
}

/// 通知权限是否已授予（Android 13+）。没权限时通知卡片不会显示，
/// 隐藏窗口后将没有任何可操作入口，调用方应据此不隐藏。
/// 其它平台没有该通道，一律视为可用（true）。
Future<bool> notifGranted() async {
  try {
    return await _channel.invokeMethod<bool>('notifGranted') ?? true;
  } catch (_) {
    return true;
  }
}

/// 打开系统里本应用的通知设置页（引导手动开启权限）。
/// 成功打开返回 true；非安卓/无实现返回 false。
Future<bool> openNotifSettings() async {
  try {
    return await _channel.invokeMethod<bool>('openNotifSettings') ?? false;
  } catch (_) {
    return false;
  }
}

/// 申请通知权限（Android 13+ 必需：POST_NOTIFICATIONS 不给，通知栏/
/// 锁屏的电台卡片根本不会显示，MediaSession 也拿不到锁屏控件）。
/// 系统只在首次弹窗，之后返回 false 表示用户已拒绝——只能引导去设置。
Future<bool> requestNotif() async {
  try {
    return await _channel.invokeMethod<bool>('requestNotif') ?? false;
  } catch (_) {
    return false;
  }
}

/// 更新通知栏/锁屏音频卡片（MediaService 前台服务 + MediaSession，
/// LXFM 同款电台体验）：台名 + 当前曲目 + 播放态按钮
/// （上一台/播放暂停/下一台/关闭），锁屏与下拉栏同卡。
/// [logoUrl] 为当前频道台标图：原生下载后作为卡片大图与锁屏封面
/// （URL 变化才重新下载，失败静默回落应用图标）。
Future<void> audioNotify(
    {required String name,
    required String program,
    required bool playing,
    String logoUrl = ''}) async {
  try {
    await _channel.invokeMethod('audioUpdate', {
      'name': name,
      'program': program,
      'playing': playing,
      'logo': logoUrl,
    });
  } catch (_) {}
}

/// 关闭通知栏/锁屏卡片（退出听电视时）
Future<void> audioStop() async {
  try {
    await _channel.invokeMethod('audioStop');
  } catch (_) {}
}

/// 注册画中画状态回调：用户点画中画窗口的全屏/关闭时由原生通知
void listenPipState(void Function(bool active)? cb) {
  _pipCb = cb;
  _ensureHandler();
}

/// 注册通知栏/锁屏卡片命令回调（playpause / prev / next / stop / restore）
void listenAudioCommands(void Function(String cmd)? cb) {
  _audioCb = cb;
  _ensureHandler();
}
