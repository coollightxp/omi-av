import 'dart:io';

/// 关闭系统：
/// - Windows：`shutdown /s /t <n> /f`
/// - Linux：`poweroff`
/// 其它平台为空操作（退出框不显示关机按钮）。
///
/// [delaySeconds] 是留给应用的收尾时间：定时关机时先发命令再退出程序，
/// 进程先死也不影响系统照常关闭；Windows 上用户还能用
/// `shutdown /a` 在倒计时内撤销。
Future<void> shutdownSystem({int delaySeconds = 0}) async {
  final t = delaySeconds.clamp(0, 600).toString();
  if (Platform.isWindows) {
    await Process.run('shutdown', ['/s', '/t', t, '/f']);
  } else if (Platform.isLinux) {
    await Process.run('shutdown', ['-h', '+${delaySeconds ~/ 60}']);
  }
}

/// 撤销一次尚未执行的定时关机（Windows `shutdown /a`）。
Future<void> cancelShutdown() async {
  if (Platform.isWindows) {
    await Process.run('shutdown', const ['/a']);
  }
}
