#include "omi_screen_recorder_plugin.h"

#include <flutter/encodable_value.h>

#include "screen_recorder_core.h"

namespace omi_screen_recorder {

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

int GetIntArg(const EncodableMap* map, const char* key, int fallback) {
  if (map == nullptr) return fallback;
  auto it = map->find(EncodableValue(key));
  if (it == map->end()) return fallback;
  if (const auto* v = std::get_if<int32_t>(&it->second)) return *v;
  if (const auto* v = std::get_if<int64_t>(&it->second)) return static_cast<int>(*v);
  return fallback;
}

}  // namespace

void OmiScreenRecorderPluginRegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<OmiScreenRecorderPlugin>(registrar);
  registrar->AddPlugin(std::move(plugin));
}

OmiScreenRecorderPlugin::OmiScreenRecorderPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar) {}

OmiScreenRecorderPlugin::~OmiScreenRecorderPlugin() = default;

void OmiScreenRecorderPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = method_call.method_name();

  if (method == "isSupported") {
    result->Success(
        EncodableValue(omi_recorder::ScreenRecorder::Instance().IsSupported()));
    return;
  }

  if (method == "start") {
    const auto* args =
        std::get_if<EncodableMap>(method_call.arguments());
    std::string path;
    if (args != nullptr) {
      auto it = args->find(EncodableValue("path"));
      if (it != args->end()) {
        if (const auto* s = std::get_if<std::string>(&it->second)) {
          path = *s;
        }
      }
    }
    const int fps = GetIntArg(args, "fps", 30);
    const int bitrate = GetIntArg(args, "bitrateMbps", 8);

    HWND hwnd = registrar_->GetView() != nullptr
                    ? registrar_->GetView()->GetNativeWindow()
                    : nullptr;
    const omi_recorder::RecorderResult r =
        omi_recorder::ScreenRecorder::Instance().Start(hwnd, path, fps, bitrate);

    EncodableMap out;
    out[EncodableValue("ok")] = EncodableValue(r.ok);
    out[EncodableValue("error")] = EncodableValue(r.error);
    result->Success(EncodableValue(out));
    return;
  }

  if (method == "stop") {
    const int64_t ms = omi_recorder::ScreenRecorder::Instance().Stop();
    EncodableMap out;
    out[EncodableValue("ok")] = EncodableValue(true);
    out[EncodableValue("durationMs")] = EncodableValue(ms);
    result->Success(EncodableValue(out));
    return;
  }

  result->NotImplemented();
}

}  // namespace omi_screen_recorder
