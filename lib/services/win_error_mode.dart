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

/// int _set_abort_behavior(unsigned int flags, unsigned int mask)
/// UCRT：abort() 的默认行为是「弹框 + 上报故障」——退出时某个原生
/// 线程（mpv / WebView2 的收尾线程）在拆解中途 abort，就会弹
/// 「omi.exe - 快速异常检测失败…进程将立即终止」。这个框不走
/// SetErrorMode 的错误模式，只能从这里关：flags 置 0 = 消息框不弹、
/// 故障不上报，abort 直接以退出码 3 结束进程。
///   _WRITE_ABORT_MSG   = 0x00000001
///   _CALL_REPORTFAULT  = 0x00000002
typedef _SetAbortBehaviorNative = Uint32 Function(Uint32, Uint32);
typedef _SetAbortBehaviorDart = int Function(int, int);

/// VOID ExitProcess(UINT uExitCode)
/// 进程级「立刻结束」：跳过 CRT 静态析构与所有仍在跑的收尾线程。
/// 退出流程里状态都已落盘（settings 先 flush），这时没有什么是
/// 必须靠「优雅关闭」才能保住的——与其赌析构链不 abort，不如
/// 在一切就绪后一枪结束。hardExit 不会返回。
typedef _ExitProcessNative = Void Function(Uint32);
typedef _ExitProcessDart = void Function(int);

void suppressWindowsCrashDialogs() {
  try {
    if (!Platform.isWindows) return;
    final k32 = DynamicLibrary.open('kernel32.dll');
    final setErr = k32
        .lookupFunction<_SetErrorModeNative, _SetErrorModeDart>('SetErrorMode');
    setErr(0x0001 | 0x0002 | 0x8000);
    // abort() 的弹框走的是 UCRT 自己的逻辑，单独关掉
    try {
      final ucrt = DynamicLibrary.open('ucrtbase.dll');
      final sab =
          ucrt.lookupFunction<_SetAbortBehaviorNative, _SetAbortBehaviorDart>(
              '_set_abort_behavior');
      sab(0, 0x00000001 | 0x00000002);
    } catch (_) {
      // 精简系统没有独立 ucrtbase（符号合并进别的模块）：跳过
    }
  } catch (_) {
    // 精简系统缺 kernel32 导出（几乎不可能）：静默跳过，不影响启动
  }
}

/// 退出流程的最后一步：直接结束进程，不进任何析构链。
/// 见 ExitGuard.quit() 的注释——「快速异常检测失败」弹窗就是
/// 析构中途 abort 弹的，优雅关闭治不了随机性，只能跳过它。
void hardExitProcess() {
  if (!Platform.isWindows) return;
  final k32 = DynamicLibrary.open('kernel32.dll');
  final exitP =
      k32.lookupFunction<_ExitProcessNative, _ExitProcessDart>('ExitProcess');
  exitP(0);
}
