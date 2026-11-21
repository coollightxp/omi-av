cmake_minimum_required(VERSION 3.14)

# 目标名必须是 <插件名>_plugin：flutter 生成的 generated_plugins.cmake
# 会 add_subdirectory 本目录并引用 $<TARGET_FILE:omi_screen_recorder_plugin>
set(PLUGIN_NAME "omi_screen_recorder_plugin" CACHE STRING "The name of the Flutter plugin library")

project(${PLUGIN_NAME} LANGUAGES CXX)

add_library(${PLUGIN_NAME} SHARED
  "omi_screen_recorder_plugin.cpp"
  "omi_screen_recorder_plugin_c_api.cpp"
  "screen_recorder_core.cpp"
)

# 不走 apply_standard_settings：那里 /W4 /WX 会让 WinRT 头文件的
# 告警直接变错误；本插件自带宽松告警级别
target_compile_features(${PLUGIN_NAME} PUBLIC cxx_std_17)
target_compile_options(${PLUGIN_NAME} PRIVATE /EHsc /W3)
target_compile_definitions(${PLUGIN_NAME} PRIVATE UNICODE _UNICODE)
target_compile_definitions(${PLUGIN_NAME} PRIVATE PLUGIN_IMPL)
# 进程回环音频 ActivateAudioInterface 声明在 NTDDI_WIN10_19H1 守卫之后，
# SDK 默认 NTDDI 低于该值会把声明藏起来（0x0A000007 = 19H1）
target_compile_definitions(${PLUGIN_NAME} PRIVATE
  _WIN32_WINNT=0x0A00
  WINVER=0x0A00
  NTDDI_VERSION=0x0A000007)

target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_app
  d3d11
  dxgi
  mfplat
  mfuuid
  mfreadwrite
  wmcodecdspuuid
  mmdevapi
  windowsapp
  ole32
)

target_include_directories(${PLUGIN_NAME} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/include")
