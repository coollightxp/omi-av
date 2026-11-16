import 'package:flutter/foundation.dart';

/// 「弹出式小菜单」正在打开（音效选单 / 线路选单，均走 showMenu）。
///
/// 底部面板整体 ExcludeFocus、按键由播放页全局分发，showMenu 弹出的
/// 路由若不放行：方向键被弹层收口吞掉、OK 直接关卡——菜单收不到任何
/// 键，表现为「鼠标能选、遥控器不能选」（2.3.24 修）。播放页据此：
/// ① Flutter 路径放行给菜单自己的焦点树（Flutter 菜单自带 closedLoop
/// 焦点遍历 + ActivateIntent 激活）；② Windows 原生钩子捕获临时关闭，
/// 让键进 Flutter；③ select/gameButtonA（遥控器 OK 常见键值，Flutter
/// 默认不绑激活）由播放页翻译成 ActivateIntent。
final ValueNotifier<bool> menuNavActive = ValueNotifier<bool>(false);
