import 'dart:async';
import 'dart:io';

// 仅用于 OSD 提示图标（Icons.cast_connected）；本文件其余部分纯 dart:io
import 'package:flutter/material.dart' show Icons;

import 'cast_log.dart';
import 'osd_bus.dart';

/// 投屏流本地中转代理。
///
/// 动机：mdk 内核对视频号 CDN（finder.video.qq.com）的 Range 断点请求
/// 会挂死——服务器接受请求但永不回数据（同 URL 在 mpv 上随便拖秒开）。
/// 经本地代理后 HTTP 层完全由我们控制：
/// - 每个请求使用全新连接（不复用可能被 CDN 挂起的连接）；
/// - 首字节停滞 15 秒：未向内核输出过字节，换全新连接整请求重试（≤3 次）；
/// - body 中途停滞 15 秒：直接断开，内核侧已开启的 avio.reconnect
///   会携当前位置重新经代理发请求（同样拿到全新连接），等价于
///   mpv 的断点续传行为。
class CastStreamProxy {
  CastStreamProxy._();
  static final CastStreamProxy instance = CastStreamProxy._();

  HttpServer? _server;

  /// 把 [rawUrl] 包装为本地代理地址；代理启动失败时返回 null（回退直连）。
  Future<String?> wrapUrl(String rawUrl) async {
    try {
      if (_server == null) {
        final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        s.listen(_handle, onError: (_) {});
        _server = s;
        CastLog.write('cast proxy listen 127.0.0.1:${s.port}');
      }
      return 'http://127.0.0.1:${_server!.port}/cast?url='
          '${Uri.encodeComponent(rawUrl)}';
    } catch (e) {
      CastLog.write('cast proxy start FAILED: $e');
      return null;
    }
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    if (s != null) {
      try {
        await s.close(force: true);
      } catch (_) {}
    }
  }

  static const _hopByHop = {
    'connection',
    'keep-alive',
    'transfer-encoding',
    'te',
    'trailer',
    'upgrade',
  };

  Future<void> _handle(HttpRequest req) async {
    final target = req.uri.queryParameters['url'];
    if (target == null || !target.startsWith('http')) {
      req.response.statusCode = 400;
      try {
        await req.response.close();
      } catch (_) {}
      return;
    }
    final range = req.headers.value(HttpHeaders.rangeHeader);
    var sent = 0;
    try {
      for (var attempt = 1;; attempt++) {
        final client = HttpClient()
          // 连接超时 15s→8s：连不上时早点失败早点重试，最坏黑洞时间
          // 从 45s（15×3）压到 ~17s（8+2+8+退避+...）
          ..connectionTimeout = const Duration(seconds: 8);
        try {
          final outReq = await client.getUrl(Uri.parse(target));
          // 裸请求转发（只带 Range）：实测给视频号 CDN 补 UA/Referer
          // 反而会被挂死（v1.0.131 实验），保持与可用直连一致
          if (range != null) {
            outReq.headers.set(HttpHeaders.rangeHeader, range);
          }
          final outResp =
              await outReq.close().timeout(const Duration(seconds: 15));
          if (sent == 0) {
            req.response.statusCode = outResp.statusCode;
            outResp.headers.forEach((name, values) {
              if (_hopByHop.contains(name.toLowerCase())) return;
              for (final v in values) {
                req.response.headers.set(name, v);
              }
            });
            // 明确声明支持断点续传（内核判定可 seek 的依据）
            req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
          }
          await for (final chunk
              in outResp.timeout(const Duration(seconds: 15))) {
            sent += chunk.length;
            req.response.add(chunk);
            await req.response.flush();
          }
          if (range != null || attempt > 1) {
            CastLog.write(
                'cast proxy ok range=${range ?? "-"} bytes=$sent attempt=$attempt');
          }
          _abortStreak = 0; // 这一路走通了，连续断流计数清零
          break;
        } catch (e) {
          if (sent == 0 && attempt < 3) {
            // 还没向内核输出任何字节：安全地换全新连接整请求重试。
            // 重试间加退避（0.5s/2s），不在 CDN 最懵的瞬间连撞三次
            CastLog.write(
                'cast proxy retry#$attempt range=${range ?? "-"}: $e');
            await Future<void>.delayed(
                Duration(milliseconds: attempt == 1 ? 500 : 2000));
            continue;
          }
          // 已输出过字节的 body 中途停滞：断开，内核 avio.reconnect
          // 会携当前位置重新经代理请求（全新连接）
          CastLog.write(
              'cast proxy abort range=${range ?? "-"} sent=$sent: $e');
          _noteAbort();
          break;
        } finally {
          client.close(force: true);
        }
      }
    } finally {
      try {
        await req.response.close();
      } catch (_) {}
    }
  }

  // ==================== 弱网提示（待办 G） ====================

  /// 连续断流计数：每次 abort +1，任意一路走通即清零。
  int _abortStreak = 0;

  /// 上次提示时刻：触发一次后冷却 30 秒，防止刷屏
  DateTime? _lastNetWarnAt;

  /// 连续 3 次 body 断流仍拉不通：OSD 明示「网络不稳」，不再静默黑屏。
  /// 弱网下用户看黑屏不知道是断网还是卡死，明示至少知道在重试。
  void _noteAbort() {
    _abortStreak++;
    if (_abortStreak < 3) return;
    final now = DateTime.now();
    final last = _lastNetWarnAt;
    if (last != null && now.difference(last) < const Duration(seconds: 30)) {
      return;
    }
    _lastNetWarnAt = now;
    _abortStreak = 0;
    OsdBus.show('投屏网络不稳，正在自动重试…', icon: Icons.cast_connected);
  }
}
