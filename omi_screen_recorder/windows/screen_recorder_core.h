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

  /// Win10 1809（build 17763）起可用：Graphics Capture 的底线。
  /// 进程回环音频要 2004，但缺声音只退化成纯视频，不作为门槛。
  bool IsSupported();

  /// 诊断串（os 版本 / supported / 进程回环 API 是否可用），
  /// 录制被判定不可用时用来解释原因
  std::string Diagnose();

  /// 启动录制。hwnd 为 Flutter 播放器窗口。
  RecorderResult Start(HWND hwnd, const std::string& pathUtf8, int fps,
                       int bitrateMbps);

  /// 停止并完成落盘（Finalize），返回本次录制毫秒数
  int64_t Stop();

  bool IsRecording() const { return running_; }

  /// 上一次录制的诊断计数（Stop 后有效）
  int64_t LastFramesCaptured() const { return lastFramesCaptured_; }
  int64_t LastFramesEncoded() const { return lastFramesEncoded_; }

 private:
  ScreenRecorder() = default;
  bool running_ = false;
  int64_t lastFramesCaptured_ = 0;
  int64_t lastFramesEncoded_ = 0;
};

}  // namespace omi_recorder

#endif  // OMI_SCREEN_RECORDER_CORE_H_
