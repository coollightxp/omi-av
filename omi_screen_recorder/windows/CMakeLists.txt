cmake_minimum_required(VERSION 3.14)

set(PLUGIN_NAME "omi_screen_recorder" CACHE STRING "The name of the Flutter plugin library")
set(PLUGIN_BUNDLED_LIBRARIES ${PLUGIN_NAME}.dll PARENT_SCOPE)

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
