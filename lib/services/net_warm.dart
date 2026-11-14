// 条件导出：Web 端为空实现，桌面/移动端做 DNS + TCP 预连接
export 'net_warm_stub.dart' if (dart.library.io) 'net_warm_io.dart';
