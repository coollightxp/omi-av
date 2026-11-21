#ifndef OMI_SCREEN_RECORDER_CORE_H_
#define OMI_SCREEN_RECORDER_CORE_H_

#include <windows.h>

#include <cstdint>
#include <string>

namespace omi_recorder {

struct RecorderResult {
  bool ok = false;
  std::string error;
};

/// Windows 系统级录制：
///   画面  Windows Graphics Capture（捕获播放器窗口，无遮挡影响）
///   声音  WASAPI 进程回环（只录本进程/WebView2 子进程的声音）
///   编码  Media Foundation SinkWriter（H.264 + AAC -> mp4，系统编码器）
/// 与播放内核（mpv/mdk）完全无关。
class ScreenRecorder {
 public:
  static ScreenRecorder& Instance();

  /// Win10 2004（build 19041）起可用：进程回环音频需要它
  bool IsSupported();

  /// 启动录制。hwnd 为 Flutter 播放器窗口。
  RecorderResult Start(HWND hwnd, const std::string& pathUtf8, int fps,
                       int bitrateMbps);

  /// 停止并完成落盘（Finalize），返回本次录制毫秒数
  int64_t Stop();

  bool IsRecording() const { return running_; }

 private:
  ScreenRecorder() = default;
  bool running_ = false;
};

}  // namespace omi_recorder

#endif  // OMI_SCREEN_RECORDER_CORE_H_
