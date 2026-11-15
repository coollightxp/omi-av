import 'dart:async';
import 'dart:io';

/// 换台预读：只做 DNS 解析 + TCP 握手，连上即断。
///
/// **绝不对流地址发 HTTP 请求**：不少 IPTV/直播服务器是单会话或带 token
/// 的，同一地址被重复请求会踢掉正在播的那条连接，表现为「一按上下键
/// 当前台就断流」。只连端口不读数据，既完成域名解析与握手预热（真正
/// 切台时少一次 DNS/TCP 往返），又完全不干扰当前播放。
Future<void> warmHost(String host, int port,
    {Duration timeout = const Duration(milliseconds: 1500)}) async {
  Socket? s;
  try {
    s = await Socket.connect(host, port, timeout: timeout);
  } catch (_) {
    // 预读失败不影响正式切台
  } finally {
    try {
      s?.destroy();
    } catch (_) {}
  }
}
