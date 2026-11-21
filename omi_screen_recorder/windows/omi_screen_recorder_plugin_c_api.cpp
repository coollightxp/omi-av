#include "include/omi_screen_recorder/omi_screen_recorder_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "omi_screen_recorder_plugin.h"

void OmiScreenRecorderPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  omi_screen_recorder::OmiScreenRecorderPluginRegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
