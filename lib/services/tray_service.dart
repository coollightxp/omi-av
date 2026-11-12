/// 托盘服务：条件导出。Web 上用占位实现，
/// 原生平台走 tray_service_io（内部再按平台判断，仅 Windows 实装）。
export 'tray_service_stub.dart'
    if (dart.library.io) 'tray_service_io.dart';
