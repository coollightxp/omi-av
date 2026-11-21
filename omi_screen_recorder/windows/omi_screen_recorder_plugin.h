#ifndef FLUTTER_PLUGIN_OMI_SCREEN_RECORDER_PLUGIN_H_
#define FLUTTER_PLUGIN_OMI_SCREEN_RECORDER_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>

namespace omi_screen_recorder {

/// C API 层（omi_screen_recorder_plugin_c_api.cpp）调用的注册入口
void OmiScreenRecorderPluginCApiRegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar);

class OmiScreenRecorderPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(
      flutter::PluginRegistrarWindows* registrar);

  explicit OmiScreenRecorderPlugin(flutter::PluginRegistrarWindows* registrar);
  virtual ~OmiScreenRecorderPlugin();

  OmiScreenRecorderPlugin(const OmiScreenRecorderPlugin&) = delete;
  OmiScreenRecorderPlugin& operator=(const OmiScreenRecorderPlugin&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  flutter::PluginRegistrarWindows* registrar_;
  // 必须持有 channel 引用：MethodChannel 析构后 handler 就失效了
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

}  // namespace omi_screen_recorder

#endif  // FLUTTER_PLUGIN_OMI_SCREEN_RECORDER_PLUGIN_H_
