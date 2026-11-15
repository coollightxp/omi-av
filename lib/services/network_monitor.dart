import 'dart:async';
import 'dart:io';

/// 网络状态检测服务。
///
/// - 启动时检测是否有网，无网则等待并重试
/// - 后台定时检测网络变化
/// - 通知监听者网络状态变化
class NetworkMonitor {
  NetworkMonitor._();
  static final NetworkMonitor instance = NetworkMonitor._();

  bool _hasNetwork = false;
  bool get hasNetwork => _hasNetwork;

  final StreamController<bool> _controller = StreamController<bool>.broadcast();
  Stream<bool> get onNetworkChanged => _controller.stream;

  Timer? _timer;
  bool _running = false;

  /// 启动网络监控
  void start() {
    if (_running) return;
    _running = true;
    _checkOnce();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _checkOnce());
  }

  /// 停止网络监控
  void stop() {
    _timer?.cancel();
    _timer = null;
    _running = false;
  }

  /// 立即检测一次网络
  Future<bool> _checkOnce() async {
    final online = await _isOnline();
    if (online != _hasNetwork) {
      _hasNetwork = online;
      _controller.add(online);
    }
    return online;
  }

  /// 检测是否有网络（尝试连接几个常用域名）
  Future<bool> _isOnline() async {
    final hosts = ['www.baidu.com', 'www.qq.com', 'www.bing.com'];
    for (final host in hosts) {
      try {
        final result = await InternetAddress.lookup(host).timeout(
          const Duration(seconds: 3),
        );
        if (result.isNotEmpty && result.first.rawAddress.isNotEmpty) {
          return true;
        }
      } catch (_) {}
    }
    return false;
  }

  /// 立即重新检测一次网络（不走 5 秒轮询缓存）。
  ///
  /// 缓存值会滞后：刚连上 Wi-Fi、后台切回前台、系统刚解除息屏限制时，
  /// `hasNetwork` 可能还是 false。调用方（如换台前的等网判断）应该用
  /// 实时结果，否则会把「其实有网」误判成断网，白等 30 秒。
  Future<bool> checkNow() => _checkOnce();

  /// 等待网络可用（阻塞直到有网或超时）
  Future<bool> waitForNetwork(
      {Duration timeout = const Duration(minutes: 5)}) async {
    final start = DateTime.now();
    while (DateTime.now().difference(start) < timeout) {
      if (await _checkOnce()) return true;
      await Future.delayed(const Duration(seconds: 3));
    }
    return _hasNetwork;
  }
}
