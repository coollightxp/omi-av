import 'dart:io';

/// 关闭系统：
/// - Windows：`shutdown /p /f` —— /p 是「立即关机、无倒计时」，
///   **不会**弹 `/s /t n` 那种「即将注销你的登录」蓝色系统通知
///   （用户明确要求：无论退出卡片的关机还是定时关机到点，都不出现
///   系统提示）。应用内的倒计时在 Dart 侧自己走，到点才调这里。
/// - Linux：`poweroff`
/// 其它平台为空操作（退出框不显示关机按钮）。
///
/// 先发命令再退出程序：进程先死也不影响系统照常关闭。
/// [delaySeconds] 已废弃（保留参数避免调用方改动），命令一律立即执行。
Future<void> shutdownSystem({int delaySeconds = 0}) async {
  assert(delaySeconds >= 0);
  if (Platform.isWindows) {
    await Process.run('shutdown', const ['/p', '/f']);
  } else if (Platform.isLinux) {
    await Process.run('poweroff', const []);
  }
}

/// 撤销一次尚未执行的定时关机（Windows `shutdown /a`）。
Future<void> cancelShutdown() async {
  if (Platform.isWindows) {
    await Process.run('shutdown', const ['/a']);
  }
}
