import 'dart:ffi';
import 'dart:io' show Platform;

/// 压掉 Windows 的系统级崩溃弹窗。
///
/// 现象（用户实测，随机出现）：播放中弹「欧米视听: omi.exe - 系统错误 /
/// Exception Processing Message 0xc0000005 - Unexpected parameters」，
/// 要点「确定」才消失。这是 mpv/WebView2 的原生线程偶发访问违例时，
/// Windows 默认弹的硬错误对话框——App 本身拦不住，只能从进程级
/// 错误模式上关掉。
///
/// SEM_FAILCRITICALERRORS(0x0001)：硬错误（含 Exception Processing
///   Message 系列）不再弹系统对话框；
/// SEM_NOGPFAULTERRORBOX(0x0002)：访问违例不再弹 GPF/WER 对话框；
/// SEM_NOOPENFILEERRORBOX(0x8000)：找不到文件不弹框。
///
/// 副作用：真崩溃时进程静默退出、不留弹窗——播放页的重试/看门狗
/// 本来就能自愈大多数瞬时错误，比每随机弹一个要用户手点的对话框好。

typedef _SetErrorModeNative = Uint32 Function(Uint32);
typedef _SetErrorModeDart = int Function(int);

void suppressWindowsCrashDialogs() {
  try {
    if (!Platform.isWindows) return;
    final k32 = DynamicLibrary.open('kernel32.dll');
    final setErr = k32
        .lookupFunction<_SetErrorModeNative, _SetErrorModeDart>('SetErrorMode');
    setErr(0x0001 | 0x0002 | 0x8000);
  } catch (_) {
    // 精简系统缺 kernel32 导出（几乎不可能）：静默跳过，不影响启动
  }
}
