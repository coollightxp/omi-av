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
# 两个宏都定义：c_api 头用 FLUTTER_PLUGIN_IMPL 判导出方向，
# PLUGIN_IMPL 是 flutter 模板惯例；缺一个都会让导出变 dllimport
target_compile_definitions(${PLUGIN_NAME} PRIVATE PLUGIN_IMPL FLUTTER_PLUGIN_IMPL)
# ActivateAudioInterface / 进程回环结构体声明藏在 NTDDI_WIN10_19H1
# 守卫后（0x0A000008 起）；SDK 默认 NTDDI 低于该值，提到安全上限
target_compile_definitions(${PLUGIN_NAME} PRIVATE
  _WIN32_WINNT=0x0A00
  WINVER=0x0A00
  NTDDI_VERSION=0x0A000010)

target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
  d3d11
  dxgi
  mfplat
  mfuuid
  mfreadwrite
  wmcodecdspuuid
  windowsapp
  ole32
)

# INTERFACE：generated_plugin_registrant.cc 要 include
# <omi_screen_recorder/...>，头文件目录必须传播给 runner 目标
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")

# 必须 install 到 runner 的 Release 目录：flutter 的插件模板里这一行就是
# 「把 dll 拷进包里」的唯一途径。缺了它 —— dll 只躺在
# build\windows\x64\plugins\ 下，打包出来的 Release 里没有它，
# 运行时注册不上 -> MissingPluginException -> isSupported 恒 false ->
# 静默回退内核转封装（投屏因此永远「没有数据」）。v2.3.72 补上。
if(NOT DEFINED INSTALL_BUNDLE_LIB_DIR)
  set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/.")
endif()
# Windows 上 DLL 属于 RUNTIME 产物，只写 LIBRARY 有不被安装的风险；
# 三个都写上，保证 dll 一定落到 Release 目录
install(TARGETS ${PLUGIN_NAME}
  RUNTIME DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime
  LIBRARY DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime
  ARCHIVE DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
