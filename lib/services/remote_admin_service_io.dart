import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// Web 管理服务回调（只使用基础类型，Web 占位实现中保持同名镜像定义）
class RemoteAdminHooks {
  /// 返回当前全部配置快照：
  /// {playLists:[...], currentPlaylistId, epgs:[...], currentEpgId}
  final Future<Map<String, dynamic>> Function() getSnapshot;

  /// 手机端保存全量配置（增删改后的列表 + 当前选中项）
  final Future<void> Function(Map<String, dynamic> data) applySnapshot;

  /// 请求重新拉取：kind = playlists / epgs / radio
  final Future<void> Function(String kind) refresh;

  /// 在线电台目录搜索：在电脑侧发请求（手机浏览器在局域网里，不必能
  /// 直连外网目录服务，也不必处理 CORS）。返回精简后的电台字段表。
  final Future<List<Map<String, dynamic>>> Function(String query, String tag)?
      searchRadio;

  /// 把搜到的一台加进「我的电台」
  final Future<void> Function(Map<String, dynamic> station)? addRadio;

  /// 从「我的电台」移除一台
  final Future<void> Function(String stationId)? removeRadio;

  /// 播放「我的电台」里的某一台（按电台 id）
  final Future<void> Function(String stationId)? playRadio;

  /// 切换当前直播源/电台源（内置电台「设为当前」）
  final Future<void> Function(String playlistId)? selectPlaylist;

  /// 恢复被删掉的内置电台精选
  final Future<void> Function()? restoreBuiltinRadio;

  /// 重新抓一次内置节目单（央视网），返回提示文案
  final Future<String> Function()? updateBuiltinEpg;

  /// 内置节目单状态：{count, at}（网页上显示「N 条节目 · 更新于 …」）
  final Future<Map<String, dynamic>> Function()? builtinEpgInfo;

  const RemoteAdminHooks({
    required this.getSnapshot,
    required this.applySnapshot,
    required this.refresh,
    this.searchRadio,
    this.addRadio,
    this.removeRadio,
    this.playRadio,
    this.selectPlaylist,
    this.restoreBuiltinRadio,
    this.updateBuiltinEpg,
    this.builtinEpgInfo,
  });
}

/// 局域网 Web 管理服务
/// 手机扫码/浏览器打开后，可以在手机上增删改直播源与 EPG。
/// 仅监听本机网卡（默认 8963 端口，占用则自动顺延），不主动访问外网。
class RemoteAdminService {
  HttpServer? _server;
  String _ip = '127.0.0.1';
  int _port = 0;
  RemoteAdminHooks? _hooks;

  bool get isRunning => _server != null;
  String get endpoint =>
      _server == null ? '' : 'http://$_ip:$_port';

  Future<void> start({required RemoteAdminHooks hooks}) async {
    if (_server != null) return;
    _hooks = hooks;
    HttpServer? server;
    // 8963 起，被占用则向后试 9 个端口
    for (var p = 8963; p < 8973 && server == null; p++) {
      try {
        server = await HttpServer.bind(InternetAddress.anyIPv4, p);
      } catch (_) {
        server = null;
      }
    }
    if (server == null) return;
    _server = server;
    _port = server.port;
    _ip = await _localIp();
    server.listen(_handle);
  }

  void stop() {
    _server?.close(force: true);
    _server = null;
    _port = 0;
  }

  Future<void> _handle(HttpRequest req) async {
    // 简单 CORS：桌面场景可能被本机页面调用
    req.response.headers
      ..add('Access-Control-Allow-Origin', '*')
      ..add('Access-Control-Allow-Methods', 'GET,POST,OPTIONS')
      ..add('Access-Control-Allow-Headers', 'Content-Type');
    if (req.method == 'OPTIONS') {
      req.response.statusCode = 204;
      await req.response.close();
      return;
    }

    final path = req.uri.path;
    try {
      if (req.method == 'GET' && path == '/') {
        req.response.headers.contentType =
            ContentType('text', 'html', charset: 'utf-8');
        req.response.headers
          ..add('Cache-Control', 'no-store, must-revalidate')
          ..add('Pragma', 'no-cache');
        req.response.write(_adminHtml);
      } else if (req.method == 'GET' && path == '/logo.png') {
        // 页头品牌图标：直接使用打包进应用图标资源，避免维护第二份图
        final data = await rootBundle.load('branding/web/Icon-192.png');
        req.response.headers.contentType = ContentType('image', 'png');
        req.response.headers.add('Cache-Control', 'public, max-age=86400');
        req.response.add(data.buffer.asUint8List());
      } else if (req.method == 'GET' && path == '/api/snapshot') {
        final data = await _hooks!.getSnapshot();
        _json(req, data);
      } else if (req.method == 'POST' && path == '/api/snapshot') {
        final body = await utf8.decoder.bind(req).join();
        final data = jsonDecode(body) as Map<String, dynamic>;
        await _hooks!.applySnapshot(data);
        _json(req, {'ok': true});
      } else if (req.method == 'POST' && path == '/api/refresh') {
        final body = await utf8.decoder.bind(req).join();
        final kind = (jsonDecode(body) as Map)['kind']?.toString() ?? '';
        await _hooks!.refresh(kind);
        _json(req, {'ok': true});
      } else if (req.method == 'GET' && path == '/api/radio/search') {
        final q = req.uri.queryParameters['q'] ?? '';
        final tag = req.uri.queryParameters['tag'] ?? '';
        final fn = _hooks!.searchRadio;
        if (fn == null) {
          req.response.statusCode = 501;
          _json(req, {'ok': false, 'error': 'not supported'});
        } else {
          final items = await fn(q, tag);
          _json(req, {'ok': true, 'items': items});
        }
      } else if (req.method == 'POST' && path == '/api/radio/add') {
        final body = await utf8.decoder.bind(req).join();
        final m = (jsonDecode(body) as Map).cast<String, dynamic>();
        await _hooks!.addRadio?.call(m);
        _json(req, {'ok': true});
      } else if (req.method == 'POST' && path == '/api/radio/remove') {
        final body = await utf8.decoder.bind(req).join();
        final id = (jsonDecode(body) as Map)['id']?.toString() ?? '';
        await _hooks!.removeRadio?.call(id);
        _json(req, {'ok': true});
      } else if (req.method == 'POST' && path == '/api/radio/play') {
        final body = await utf8.decoder.bind(req).join();
        final id = (jsonDecode(body) as Map)['id']?.toString() ?? '';
        await _hooks!.playRadio?.call(id);
        _json(req, {'ok': true});
      } else if (req.method == 'POST' && path == '/api/playlist/select') {
        final body = await utf8.decoder.bind(req).join();
        final id = (jsonDecode(body) as Map)['id']?.toString() ?? '';
        await _hooks!.selectPlaylist?.call(id);
        _json(req, {'ok': true});
      } else if (req.method == 'POST' && path == '/api/radio/restore') {
        await _hooks!.restoreBuiltinRadio?.call();
        _json(req, {'ok': true});
      } else if (req.method == 'GET' && path == '/api/epg/builtin') {
        final info = await _hooks!.builtinEpgInfo?.call() ?? {};
        _json(req, {'ok': true, ...info});
      } else if (req.method == 'POST' && path == '/api/epg/builtin-update') {
        final fn = _hooks!.updateBuiltinEpg;
        if (fn == null) {
          req.response.statusCode = 501;
          _json(req, {'ok': false, 'error': 'not supported'});
        } else {
          final msg = await fn();
          _json(req, {'ok': true, 'message': msg});
        }
      } else {
        req.response.statusCode = 404;
        req.response.write('not found');
      }
    } catch (e) {
      req.response.statusCode = 500;
      _json(req, {'ok': false, 'error': '$e'});
    } finally {
      await req.response.close();
    }
  }

  void _json(HttpRequest req, Object data) {
    req.response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    req.response.write(jsonEncode(data));
  }

  Future<String> _localIp() async {
    try {
      final ifs = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      String best = '';
      var bestScore = -1;
      for (final i in ifs) {
        final name = i.name.toLowerCase();
        final isVirtual = name.contains('virtual') ||
            name.contains('vmware') ||
            name.contains('hyper-v') ||
            name.contains('vethernet') ||
            name.contains('wsl') ||
            name.contains('docker') ||
            name.contains('vbox');
        for (final a in i.addresses) {
          if (a.isLoopback) continue;
          final addr = a.address;
          var score = 0;
          if (addr.startsWith('192.168.')) {
            score = 100;
          } else if (addr.startsWith('10.')) {
            score = 80;
          } else if (addr.startsWith('172.')) {
            score = 60;
          } else {
            score = 10;
          }
          if (isVirtual) score -= 50;
          if (score > bestScore) {
            bestScore = score;
            best = addr;
          }
        }
      }
      return best.isEmpty ? '127.0.0.1' : best;
    } catch (_) {
      return '127.0.0.1';
    }
  }
}

/// 手机管理页（单文件，原生 JS，无外部依赖）。
/// 视觉与兼容性说明：
/// - 不使用 CSS Grid（旧版微信 X5 内核对 grid 支持差，会把整页挤成
///   竖条）；按钮用 flex-basis:calc() 固定等分，white-space:nowrap
///   防止文字竖排
/// - 所有滚动/固定布局只用 flex 与固定定位，并给 -webkit- 前缀
const _adminHtml = r'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<meta name="format-detection" content="telephone=no">
<title>欧米视听 · 设置管理</title>
<style>
*{box-sizing:border-box;margin:0;padding:0;-webkit-tap-highlight-color:transparent}
html{-webkit-text-size-adjust:100%}
body{
  font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft YaHei",sans-serif;
  background:#0d0f14;
  background-image:-webkit-linear-gradient(180deg,#12151d 0,#0d0f14 320px);
  color:#e8eaed;
  padding-bottom:calc(96px + env(safe-area-inset-bottom));
  -webkit-font-smoothing:antialiased;
}
button{font-family:inherit;cursor:pointer;-webkit-appearance:none;appearance:none}
.top{
  position:-webkit-sticky;position:sticky;top:0;z-index:20;
  background:rgba(18,21,29,.96);
  -webkit-backdrop-filter:blur(8px);backdrop-filter:blur(8px);
  border-bottom:1px solid #232838;
  padding:calc(12px + env(safe-area-inset-top)) 16px 12px;
}
.brand{display:-webkit-flex;display:flex;-webkit-align-items:center;align-items:center}
.logo{
  width:36px;height:36px;border-radius:9px;margin-right:10px;-webkit-flex:0 0 auto;flex:0 0 auto;
  display:block;background:#161a23;
  -webkit-box-shadow:0 3px 10px rgba(0,0,0,.4);box-shadow:0 3px 10px rgba(0,0,0,.4);
}
.brand .titles{-webkit-flex:1 1 auto;flex:1 1 auto;min-width:0}
.brand h1{font-size:17px;font-weight:600;letter-spacing:.2px;line-height:1.25}
.brand .sub{font-size:11.5px;color:#7e879c;margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.brand .sub b{color:#9fb2e8;font-weight:500}
.seg-tabs{
  display:-webkit-flex;display:flex;
  margin-top:12px;background:#0c0e13;border:1px solid #222736;border-radius:11px;padding:3px;
}
.seg-tabs button{
  -webkit-flex:1 1 0;flex:1 1 0;min-width:0;
  padding:9px 2px;border:none;border-radius:8px;
  background:transparent;color:#8b93a5;font-size:12.5px;font-weight:500;
  -webkit-transition:background .15s,color .15s;transition:background .15s,color .15s;
}
.seg-tabs button.on{background:#2563eb;color:#fff;font-weight:600}
/* 电台/搜索相关 */
.chips{display:-webkit-flex;display:flex;-webkit-flex-wrap:wrap;flex-wrap:wrap;margin:8px -4px -4px}
.chip{
  padding:7px 12px;margin:4px;border-radius:99px;border:1px solid #2b3242;
  background:#1d2330;color:#b9c4da;font-size:12.5px;white-space:nowrap;
}
.chip.on{background:#2563eb;border-color:#2563eb;color:#fff}
.search-row{display:-webkit-flex;display:flex;margin-top:10px}
.search-row input{-webkit-flex:1 1 auto;flex:1 1 auto;min-width:0;margin-right:8px}
.search-row .btn{-webkit-flex:0 0 84px;flex:0 0 84px;height:44px}
.st-item{display:-webkit-flex;display:flex;-webkit-align-items:center;align-items:center;padding:11px 0;border-top:1px solid #1e2433}
.st-item:first-child{border-top:none}
.st-info{-webkit-flex:1 1 auto;flex:1 1 auto;min-width:0;padding-right:10px}
.st-name{font-size:14px;color:#e8eaed;line-height:1.35;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.st-sub{font-size:11.5px;color:#6b7488;margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.st-item .btn{-webkit-flex:0 0 auto;flex:0 0 auto;height:34px;padding:0 14px;font-size:13px}
.st-item .btn+.btn{margin-left:8px}
.wrap{padding:14px 14px 0}
.card{
  background:#161a23;border:1px solid #232a3a;border-radius:14px;
  padding:14px 14px 12px;margin-bottom:12px;
  -webkit-box-shadow:0 2px 10px rgba(0,0,0,.25);box-shadow:0 2px 10px rgba(0,0,0,.25);
}
.card.is-cur{border-color:#27583c;background:#151d22}
.card-head{display:-webkit-flex;display:flex;-webkit-align-items:center;align-items:center}
.card .name{
  -webkit-flex:1 1 auto;flex:1 1 auto;min-width:0;
  font-size:16px;font-weight:600;line-height:1.35;
  white-space:nowrap;overflow:hidden;text-overflow:ellipsis;
}
.badge{
  -webkit-flex:0 0 auto;flex:0 0 auto;margin-left:8px;
  font-size:11px;font-weight:600;color:#5fd993;
  border:1px solid #27583c;background:#123524;
  padding:3px 9px;border-radius:99px;white-space:nowrap;
}
.url{
  margin-top:9px;padding:8px 10px;border-radius:8px;
  background:#0e1118;border:1px solid #1e2433;
  font-size:12px;color:#93a0b8;line-height:1.55;
  word-break:break-all;
  font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
}
.meta{margin-top:8px;font-size:11.5px;color:#62708e;line-height:1.5}
.meta .tag{display:inline-block;color:#8ea0cc;margin-right:6px}
.acts{display:-webkit-flex;display:flex;margin-top:12px}
.acts+.acts{margin-top:8px}
.btn{
  height:40px;border-radius:9px;border:1px solid #2b3242;background:#1d2330;
  color:#cfd6e6;font-size:13.5px;font-weight:500;
  display:-webkit-flex;display:flex;-webkit-align-items:center;align-items:center;-webkit-justify-content:center;justify-content:center;
  white-space:nowrap;overflow:hidden;
  -webkit-transition:background .12s;transition:background .12s;
}
.btn:active{background:#283144}
.acts .b3{-webkit-flex:0 0 calc((100% - 16px)/3);flex:0 0 calc((100% - 16px)/3);min-width:0;margin-right:8px}
.acts .b3:last-child{-webkit-flex:1 1 0;flex:1 1 0;margin-right:0}
.acts .b2{-webkit-flex:0 0 calc((100% - 8px)/2);flex:0 0 calc((100% - 8px)/2);min-width:0;margin-right:8px}
.acts .b2:last-child{margin-right:0}
.btn.ok{background:#153d28;border-color:#1f5d3c;color:#62e39b}
.btn.ok:active{background:#1b4d32}
.btn.danger{background:#351c23;border-color:#5b2733;color:#ff8a95}
.btn.danger:active{background:#47222c}
.group-title{font-size:12px;color:#7e879c;margin:4px 2px 9px;font-weight:600;letter-spacing:.5px}
.sw-row{
  display:-webkit-flex;display:flex;-webkit-align-items:center;align-items:center;
  background:#161a23;border:1px solid #232a3a;border-radius:14px;
  padding:14px 14px;margin-bottom:10px;
}
.sw-row:active{background:#1a1f2b}
.sw-text{-webkit-flex:1 1 auto;flex:1 1 auto;min-width:0;padding-right:12px}
.sw-title{font-size:15px;color:#e8eaed;font-weight:500;line-height:1.3}
.sw-sub{font-size:11.5px;color:#6b7488;margin-top:3px;line-height:1.4}
.sw-track{
  -webkit-flex:0 0 auto;flex:0 0 auto;
  width:46px;height:27px;border-radius:99px;background:#2c3344;
  position:relative;-webkit-transition:background .15s;transition:background .15s;
}
.sw-track .sw-thumb{
  position:absolute;top:3px;left:3px;width:21px;height:21px;border-radius:50%;
  background:#fff;
  -webkit-transition:left .15s;transition:left .15s;
  -webkit-box-shadow:0 1px 3px rgba(0,0,0,.4);box-shadow:0 1px 3px rgba(0,0,0,.4);
}
.sw-track.on{background:#2563eb}
.sw-track.on .sw-thumb{left:22px}
.sw-row.col{display:block;padding:14px 14px 16px}
.sw-row.col .sw-text{padding-right:0}
.range{
  width:100%;height:30px;margin-top:10px;padding:0;border:none;background:transparent;
  -webkit-appearance:none;appearance:none;outline:none;
}
.range::-webkit-slider-runnable-track{height:5px;border-radius:99px;background:#2c3344}
.range::-webkit-slider-thumb{
  -webkit-appearance:none;appearance:none;width:20px;height:20px;border-radius:50%;
  background:#3b82f6;margin-top:-7.5px;border:2px solid #0f131b;
  -webkit-box-shadow:0 2px 6px rgba(0,0,0,.5);box-shadow:0 2px 6px rgba(0,0,0,.5);
}
.range::-moz-range-track{height:5px;border-radius:99px;background:#2c3344}
.range::-moz-range-thumb{width:18px;height:18px;border-radius:50%;background:#3b82f6;border:none}
#scale-val{color:#9fb2e8;font-weight:600;font-size:13px}
.help-card{padding:4px 2px}
.help-item{display:-webkit-flex;display:flex;-webkit-align-items:flex-start;align-items:flex-start;gap:10px;margin:0 0 12px}
.help-k{
  -webkit-flex:0 0 auto;flex:0 0 auto;
  background:#2563eb;color:#fff;font-weight:700;font-size:11px;
  padding:2px 6px;border-radius:4px;min-width:28px;text-align:center;
  margin-top:1px;
}
.help-v{font-size:13px;color:#c8cde0;line-height:1.55;word-break:break-word}
.help-link{color:#3b82f6;text-decoration:none;border-bottom:1px dashed #3b82f6}
.set-hint{font-size:11.5px;color:#55607a;margin:2px 2px 0;line-height:1.6}
.fab{
  position:fixed;right:18px;
  bottom:calc(20px + env(safe-area-inset-bottom));
  width:54px;height:54px;border-radius:50%;
  border:none;color:#fff;font-size:30px;line-height:54px;text-align:center;
  background:-webkit-linear-gradient(135deg,#3b82f6,#2563eb);
  -webkit-box-shadow:0 8px 22px rgba(37,99,235,.45);box-shadow:0 8px 22px rgba(37,99,235,.45);
  z-index:30;padding:0;
}
.fab:active{-webkit-transform:scale(.94);transform:scale(.94)}
.sheet-mask{
  position:fixed;top:0;right:0;bottom:0;left:0;background:rgba(0,0,0,.62);
  display:none;-webkit-align-items:flex-end;align-items:flex-end;z-index:50;
}
.sheet-mask.show{display:-webkit-flex;display:flex}
.sheet{
  background:#161a23;width:100%;
  border-radius:20px 20px 0 0;
  padding:8px 16px calc(18px + env(safe-area-inset-bottom));
  max-height:88vh;overflow:auto;-webkit-overflow-scrolling:touch;
}
.handle{width:38px;height:4px;border-radius:2px;background:#333b4d;margin:6px auto 2}
.sheet h2{font-size:17px;margin:8px 0 12px;font-weight:600}
label{display:block;font-size:13px;color:#98a2b8;margin:12px 0 7px}
input{
  width:100%;padding:13px;border-radius:11px;
  border:1px solid #2a3040;background:#0f131b;color:#e8eaed;font-size:15px;
  -webkit-appearance:none;appearance:none;outline:none;
}
input:focus{border-color:#3b82f6}
.seg{display:-webkit-flex;display:flex}
.seg button+button{margin-left:8px}
.seg button{
  -webkit-flex:1 1 0;flex:1 1 0;min-width:0;
  padding:11px 0;border-radius:10px;border:1px solid #2a3040;
  background:#0f131b;color:#98a2b8;font-size:14px;white-space:nowrap;
}
.seg button.on{background:#2563eb;border-color:#2563eb;color:#fff;font-weight:600}
.sheet-actions{display:-webkit-flex;display:flex;margin-top:20px}
.sheet-actions .btn+.btn{margin-left:10px}
.sheet-actions .btn{-webkit-flex:1 1 0;flex:1 1 0;height:46px;font-size:15.5px;border-radius:11px}
.btn.primary{background:#2563eb;border-color:#2563eb;color:#fff}
.btn.primary:active{background:#1d4ed8}
.empty{text-align:center;color:#6b7488;padding:72px 24px;font-size:14px;line-height:1.7}
.empty .ic{
  width:64px;height:64px;border-radius:18px;margin:0 auto 16px;
  background:#161a23;border:1px solid #232a3a;
  display:-webkit-flex;display:flex;-webkit-align-items:center;align-items:center;-webkit-justify-content:center;justify-content:center;
  font-size:28px;color:#3d475c;
}
.loading{text-align:center;color:#6b7488;padding:72px 0;font-size:14px}
.toast{
  position:fixed;left:50%;bottom:calc(104px + env(safe-area-inset-bottom));
  -webkit-transform:translateX(-50%);transform:translateX(-50%);
  background:rgba(22,26,35,.97);padding:11px 20px;border-radius:99px;
  font-size:14px;display:none;z-index:80;border:1px solid #2d3547;
  white-space:nowrap;max-width:88%;overflow:hidden;text-overflow:ellipsis;
}
</style>
</head>
<body>
<div class="top">
  <div class="brand">
    <img class="logo" src="/logo.png" alt="欧米视听">
    <div class="titles">
      <h1>欧米视听</h1>
      <div class="sub">设置管理 · <b id="host"></b> · 自动保存</div>
    </div>
  </div>
  <div class="seg-tabs">
    <button id="tab-pl" class="on" onclick="switchTab('pl')">直播源</button>
    <button id="tab-radio" onclick="switchTab('radio')">电台</button>
    <button id="tab-epg" onclick="switchTab('epg')">EPG</button>
    <button id="tab-play" onclick="switchTab('play')">播放</button>
    <button id="tab-set" onclick="switchTab('set')">系统</button>
    <button id="tab-help" onclick="switchTab('help')">说明</button>
  </div>
</div>
<div class="wrap" id="list"><div class="loading">加载中…</div></div>
<button class="fab" id="fab" aria-label="添加" onclick="openEdit()">+</button>
<div class="sheet-mask" id="mask" onclick="if(event.target===this)closeEdit()">
  <div class="sheet">
    <div class="handle"></div>
    <h2 id="sheet-title">添加</h2>
    <label>名称</label>
    <input id="f-name" placeholder="例如：我的电视">
    <div id="type-wrap">
      <label>类型</label>
      <div class="seg">
        <button id="t-url" class="on" onclick="setType('url')">网络地址</button>
        <button id="t-local" onclick="setType('local')">本地文件</button>
      </div>
    </div>
    <label id="url-label">地址 URL</label>
    <input id="f-url" placeholder="http://... 或本地文件路径" autocapitalize="off" autocorrect="off">
    <div class="sheet-actions">
      <button class="btn" onclick="closeEdit()">取消</button>
      <button class="btn primary" onclick="saveEdit()">保存</button>
    </div>
  </div>
</div>
<div class="toast" id="toast"></div>
<script>
var hostEl=document.getElementById('host');
hostEl.textContent=location.host||'Omi';
var state={playlists:[],epgs:[],radios:[],currentPlaylistId:null,currentEpgId:null,
  radioBuiltin:{},settings:{}};
var tab='pl', editing=null, editType='url';
var radioResults=null, radioBusy=false, radioTag='', radioQ='';
var TABS=['pl','radio','epg','play','set','help'];
function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]})}
function findById(arr,id){for(var i=0;i<arr.length;i++)if(arr[i].id===id)return arr[i];return null}
function el(id){return document.getElementById(id)}
function load(){
  fetch('/api/snapshot').then(function(r){return r.json()}).then(function(d){state=d;render()})
    .catch(function(){el('list').innerHTML='<div class="empty"><div class="ic">!</div>加载失败<br>请确认手机与电脑在同一 Wi-Fi</div>'});
}
function switchTab(t){
  tab=t;
  for(var i=0;i<TABS.length;i++){el('tab-'+TABS[i]).className=TABS[i]===t?'on':''}
  // 只有直播源/EPG 有「添加」操作
  el('fab').style.display=(t==='pl'||t==='epg')?'block':'none';
  render();
}
function fmtTime(iso){
  if(!iso)return '';
  var d=new Date(iso),p=function(n){return(n<10?'0':'')+n};
  return d.getFullYear()+'/'+p(d.getMonth()+1)+'/'+p(d.getDate())+' '+p(d.getHours())+':'+p(d.getMinutes());
}
function render(){
  if(tab==='radio'){renderRadio();return}
  if(tab==='play'){renderPlayer();return}
  if(tab==='set'){renderSystem();return}
  if(tab==='help'){renderHelp();return}
  if(tab==='epg'){renderEpg();return}
  renderSources();
}

// ==================== 直播源 ====================
function renderSources(){
  var items=(state.playlists||[]).filter(function(p){return !p.radio});
  var curId=state.currentPlaylistId;
  var box=el('list');
  var html='<div class="set-hint" style="margin:0 2px 10px">电视/直播源。电台在「电台」标签里管理；'
    +'内置源随安装包发布，只能「设为当前」，不能删除或改地址。</div>';
  if(!items.length){
    box.innerHTML=html+'<div class="empty"><div class="ic">+</div>暂无直播源<br>点右下角 + 添加</div>';
    return;
  }
  for(var i=0;i<items.length;i++){
    var it=items[i], cur=it.id===curId, builtin=it.type==='builtin';
    var meta='<div class="meta"><span class="tag">'
      +(builtin?'内置':(it.type==='local'?'本地文件':'网络地址'))
      +'</span>'+(builtin?'随安装包发布 · 地址不可改':'自动识别格式')
      +(it.lastUpdated?' · 更新 '+fmtTime(it.lastUpdated):'')+'</div>';
    var row1='';
    if(!cur)row1+='<button class="btn ok b3" onclick="selectItem(\''+it.id+'\')">设为当前</button>';
    var rc=cur?'b2':'b3';
    if(!builtin)row1+='<button class="btn '+rc+'" onclick="refreshItem()">刷新</button>'
      +'<button class="btn '+rc+'" onclick="copyItem(\''+it.id+'\')">复制</button>';
    var row2='';
    if(!builtin)row2='<div class="acts">'
      +'<button class="btn b2" onclick="openEdit(\''+it.id+'\')">编辑</button>'
      +'<button class="btn danger b2" onclick="delItem(\''+it.id+'\')">删除</button></div>';
    html+='<div class="card'+(cur?' is-cur':'')+'">'
      +'<div class="card-head"><div class="name">'+esc(it.name)+'</div>'
      +(builtin?'<span class="badge" style="color:#9fb2e8;border-color:#2c3a5e;background:#141c2c">内置</span>':'')
      +(cur?'<span class="badge">播放中</span>':'')+'</div>'
      // 内置源不给看地址：assets 路径没有意义，看介绍就行
      +(builtin?'':'<div class="url">'+esc(it.url)+'</div>')+meta
      +'<div class="acts">'+row1+'</div>'+row2+'</div>';
  }
  box.innerHTML=html;
}

// ==================== 电台 ====================
function renderRadio(){
  var box=el('list');
  var b=state.radioBuiltin||{};
  var lib=state.radios||[];
  var html='<div class="group-title">内置电台</div>';
  if(b.exists){
    html+='<div class="card'+(b.current?' is-cur':'')+'">'
      +'<div class="card-head"><div class="name">内置电台精选</div>'
      +'<span class="badge" style="color:#9fb2e8;border-color:#2c3a5e;background:#141c2c">内置</span>'
      +(b.current?'<span class="badge">当前</span>':'')+'</div>'
      +'<div class="meta"><span class="tag">出厂自带</span>电视伴音 / 央广 / 省市台 / 音乐 / 故事，共约 60 个台</div>'
      +'<div class="meta">内置台随安装包发布，单个不可删；要停用请到电脑上的设置里整源移除</div>';
    if(!b.current){
      html+='<div class="acts"><button class="btn ok" onclick="selectPlaylist(\''+(b.id||'omi-builtin-radio')+'\')">设为当前</button></div>';
    }
    html+='</div>';
  }else{
    html+='<div class="card"><div class="card-head"><div class="name">内置电台精选已停用</div></div>'
      +'<div class="meta">恢复后重新加入出厂自带的电台（不影响「我的电台」）</div>'
      +'<div class="acts"><button class="btn ok" onclick="restoreRadio()">恢复内置电台</button></div></div>';
  }
  // 搜索
  html+='<div class="group-title">在线搜索</div>'
    +'<div class="card"><div class="card-head"><div class="name">搜台</div></div>'
    +'<div class="search-row"><input id="r-q" placeholder="台名，如：中国之声" value="'+esc(radioQ)+'"'
    +' onkeydown="if(event.key===\'Enter\'){event.preventDefault();doRadioSearch()}">'
    +'<button class="btn primary" onclick="doRadioSearch()">搜索</button></div>'
    +'<div class="chips">'+[['新闻','news'],['音乐','music'],['交通','traffic'],['故事','talk'],['戏曲','opera'],['体育','sports'],['财经','business'],['怀旧','oldies']]
      .map(function(t){return '<button class="chip'+(radioTag===t[1]?' on':'')+'" onclick="searchTag(\''+t[1]+'\')">'+t[0]+'</button>'}).join('')
    +'</div>'
    +'<div class="meta">搜索在电脑侧发起，手机只要能连上电脑就行；搜到的台点「加入」进「我的电台」</div></div>';
  if(radioBusy){
    html+='<div class="loading" style="padding:28px 0">搜索中…</div>';
  }else if(radioResults){
    if(!radioResults.length){
      html+='<div class="empty" style="padding:28px 0">没搜到台<br>换个关键词，或点上面的分类标签</div>';
    }else{
      html+='<div class="group-title">搜索结果 · '+radioResults.length+' 个</div><div class="card">';
      for(var i=0;i<radioResults.length;i++){
        var s=radioResults[i], has=hasStation(s.id);
        html+='<div class="st-item"><div class="st-info"><div class="st-name">'+esc(s.name)+'</div>'
          +'<div class="st-sub">'+esc(stSub(s))+'</div></div>'
          +(has?'<button class="btn" disabled style="opacity:.55">已加入</button>'
              :'<button class="btn ok" onclick="addStation('+i+')">加入</button>')
          +'</div>';
      }
      html+='</div>';
    }
  }
  // 我的电台
  html+='<div class="group-title">我的电台'+(lib.length?' · '+lib.length+' 个':'')+'</div>';
  if(!lib.length){
    html+='<div class="empty" style="padding:32px 0">还没有收藏的台<br>在上面搜一个，点「加入」</div>';
  }else{
    html+='<div class="card">';
    for(var j=0;j<lib.length;j++){
      var st=lib[j];
      html+='<div class="st-item"><div class="st-info"><div class="st-name">'+esc(st.name)+'</div>'
        +'<div class="st-sub">'+esc(stSub(st))+'</div></div>'
        +'<button class="btn ok" onclick="playStation(\''+esc(st.id)+'\')">播放</button>'
        +'<button class="btn danger" onclick="removeStation(\''+esc(st.id)+'\',\''+esc(st.name).replace(/'/g,'')+'\')">移除</button>'
        +'</div>';
    }
    html+='</div>';
  }
  box.innerHTML=html;
}
function stSub(s){
  var p=[];
  if(s.country)p.push(s.country);
  if(s.bitrate>0)p.push(s.bitrate+'kbps');
  if(s.codec)p.push(String(s.codec).toUpperCase());
  if(!p.length&&s.tags)p.push(String(s.tags).split(',').slice(0,2).join('/'));
  return p.join(' · ');
}
function hasStation(id){
  var lib=state.radios||[];
  for(var i=0;i<lib.length;i++)if(lib[i].id===id)return true;
  return false;
}
function doRadioSearch(){
  var q=el('r-q')?el('r-q').value.trim():'';
  radioQ=q;radioTag='';radioRun(q,'');
}
function searchTag(tag){
  radioTag=tag;radioQ='';radioRun('',tag);
}
function radioRun(q,tag){
  radioBusy=true;radioResults=null;renderRadio();
  fetch('/api/radio/search?q='+encodeURIComponent(q)+'&tag='+encodeURIComponent(tag))
    .then(function(r){return r.json()})
    .then(function(d){
      radioBusy=false;
      radioResults=(d&&d.items)||[];
      renderRadio();
      if(!radioResults.length)toast('没搜到，换个词试试');
    })
    .catch(function(){radioBusy=false;radioResults=[];renderRadio();toast('搜索失败：电脑连不上电台目录')});
}
function addStation(i){
  var st=radioResults[i];
  if(!st)return;
  fetch('/api/radio/add',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(st)})
    .then(function(){toast('已加入「我的电台」');load()});
}
function removeStation(id,name){
  if(!confirm('从「我的电台」移除'+(name?'「'+name+'」':'')+'？'))return;
  fetch('/api/radio/remove',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id:id})})
    .then(function(){toast('已移除');load()});
}
function playStation(id){
  fetch('/api/radio/play',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id:id})})
    .then(function(){toast('已发送到电脑播放')});
}
function selectPlaylist(id){
  fetch('/api/playlist/select',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id:id})})
    .then(function(){toast('已切换');setTimeout(load,300)});
}
function restoreRadio(){
  fetch('/api/radio/restore',{method:'POST'}).then(function(){toast('已恢复内置电台');setTimeout(load,400)});
}

// ==================== EPG ====================
function renderEpg(){
  var items=state.epgs||[], curId=state.currentEpgId, box=el('list');
  if(!items.length){
    box.innerHTML='<div class="empty"><div class="ic">+</div>暂无节目单<br>点右下角 + 添加</div>';
    return;
  }
  var html='';
  for(var i=0;i<items.length;i++){
    var it=items[i], cur=it.id===curId;
    // 内置节目单：地址是 local://（App 自己从央视网抓的），不给编辑/复制
    var builtin=String(it.url||'').indexOf('local://')===0;
    var row1='';
    if(!cur)row1+='<button class="btn ok b3" onclick="selectItem(\''+it.id+'\')">设为当前</button>';
    var rc=cur?'b2':'b3';
    if(builtin){
      row1+='<button class="btn '+rc+'" onclick="updateBuiltinEpg(this)">立即更新</button>';
    }else{
      row1+='<button class="btn '+rc+'" onclick="refreshItem()">刷新</button>'
        +'<button class="btn '+rc+'" onclick="copyItem(\''+it.id+'\')">复制</button>';
    }
    var row2=builtin
      ? '<button class="btn danger b2" onclick="delItem(\''+it.id+'\')">删除</button>'
      : '<button class="btn b2" onclick="openEdit(\''+it.id+'\')">编辑</button>'
        +'<button class="btn danger b2" onclick="delItem(\''+it.id+'\')">删除</button>';
    html+='<div class="card'+(cur?' is-cur':'')+'">'
      +'<div class="card-head"><div class="name">'+esc(it.name)+'</div>'
      +(builtin?'<span class="badge">内置</span>':'')
      +(cur?'<span class="badge">使用中</span>':'')+'</div>'
      +(builtin
        ? '<div class="meta">每天从央视网获取今天+明天，不走第三方 EPG 站点</div>'
        : '<div class="url">'+esc(it.url)+'</div>')
      +'<div class="acts">'+row1+'</div><div class="acts">'+row2+'</div></div>';
  }
  box.innerHTML=html;
}
function updateBuiltinEpg(btn){
  if(btn){btn.disabled=true;btn.textContent='更新中…'}
  fetch('/api/epg/builtin-update',{method:'POST'}).then(function(r){return r.json()})
    .then(function(d){toast(d.message||(d.ok?'已更新':'更新失败'));load()})
    .catch(function(){toast('更新失败：电脑端没响应')})
    .then(function(){if(btn){btn.disabled=false;btn.textContent='立即更新'}});
}

// ==================== 设置通用构件 ====================
function switchCard(key,title,sub){
  var s=state.settings||{};
  var on=s[key]===true;
  return '<div class="sw-row" onclick="toggleSetting(\''+key+'\')">'
    +'<div class="sw-text"><div class="sw-title">'+title+'</div>'
    +'<div class="sw-sub">'+sub+'</div></div>'
    +'<div class="sw-track'+(on?' on':'')+'"><div class="sw-thumb"></div></div></div>';
}
function choiceCard(key,title,sub,opts,cur){
  var s=state.settings||{};
  return '<div class="sw-row col"><div class="sw-text">'
    +'<div class="sw-title">'+title+'</div>'
    +(sub?'<div class="sw-sub">'+sub+'</div>':'')+'</div>'
    +'<div class="seg" style="margin-top:10px">'
    +opts.map(function(o){
      var on=String(cur)===String(o[0]);
      var arg=(typeof o[0]==='number')?o[0]:("'"+o[0]+"'");
      return '<button class="'+(on?'on':'')+'" onclick="setChoice(\''+key+'\','+arg+')">'+o[1]+'</button>';
    }).join('')
    +'</div></div>';
}
var rangeTimer=null;
function rangeCard(key,title,sub,min,max,step,val,dec,suf){
  var id='rg-'+key;
  return '<div class="sw-row col"><div class="sw-text">'
    +'<div class="sw-title">'+title+' <span id="'+id+'-v" style="color:#9fb2e8;font-size:12.5px">'
      +(val).toFixed(dec)+suf+'</span></div>'
    +(sub?'<div class="sw-sub">'+sub+'</div>':'')+'</div>'
    +'<input type="range" class="range" min="'+min+'" max="'+max+'" step="'+step+'" value="'+val+'"'
    +' oninput="onRange(\''+key+'\',this.value,'+dec+',\''+suf+'\')" onchange="onRangeEnd()"></div>';
}
function onRange(key,v,dec,suf){
  if(!state.settings)state.settings={};
  var num=parseFloat(v);
  if(key==='autoHideDelaySec')state.settings.autoHideDelay=Math.round(num*1000);
  else state.settings[key]=num;
  var lab=el('rg-'+key+'-v');
  if(lab)lab.textContent=num.toFixed(dec)+suf;
  clearTimeout(rangeTimer);
  rangeTimer=setTimeout(function(){persist()},500);
}
function onRangeEnd(){clearTimeout(rangeTimer);persist().then(function(){toast('已保存')})}
function toggleSetting(key){
  if(!state.settings)state.settings={};
  if(key==='remoteAdminEnabled'&&state.settings[key]===true){
    if(!confirm('关闭后这个网页会立即断开，手机就没法再远程管理了。确定关闭？'))return;
  }
  state.settings[key]=!state.settings[key];
  persist().then(function(){render();toast('已'+(state.settings[key]?'开启':'关闭'))});
}
function setChoice(key,val){
  if(!state.settings)state.settings={};
  if(typeof val==='string'&&/^-?\d+$/.test(val))val=parseInt(val,10);
  state.settings[key]=val;
  persist().then(function(){render();toast('已保存')});
}

// ==================== 播放 ====================
function renderPlayer(){
  var s=state.settings||{};
  var html='<div class="group-title">播放</div>';
  html+=choiceCard('preferredQuality','画质偏好','网页频道按偏好切档；直播流清晰度由源决定',
    [['auto','自动'],['low','480p'],['medium','720p'],['high','1080p'],['ultra','4K']],
    s.preferredQuality||'auto');
  html+=choiceCard('playEngine','播放内核','换台生效。MDK 画面最稳、叠面板不闪黑；MPV 滤镜/录制/电平最全',
    [['mpv','MPV'],['mdk','MDK']], s.playEngine||'mdk');
  html+=choiceCard('audioPreset','声音实验室','仅内置播放器生效，网页频道不支持',
    [['','标准'],['voice','人声'],['bass','低音'],['night','夜间']], s.audioPreset||'');
  html+=switchCard('autoPlayNext','自动播放下一频道','当前节目结束后自动切台');
  html+=switchCard('resumeLastChannel','启动时恢复上次频道','关闭后启动停在「请选择频道」，不发任何网络请求');
  html+=switchCard('spectrumTexture','电台真波形纹理（实验）','让 mpv 直接输出波形画面，个别流可能黑屏；换台生效');
  html+=switchCard('radioMeter','电台电平驱动波形（实验）','波形跟着真实响度起伏，个别机器会出现电台无声');
  html+=rangeCard('gestureSensitivity','手势灵敏度','左右滑调音量/亮度的跟手程度',0.5,2,0.1,
    (typeof s.gestureSensitivity==='number'?s.gestureSensitivity:1),1,'x');
  html+=rangeCard('autoHideDelaySec','面板自动隐藏','底部控制面板停手后多久收起',1,10,1,
    Math.round((typeof s.autoHideDelay==='number'?s.autoHideDelay:3000)/1000),0,' 秒');
  html+=choiceCard('sourceTimeoutSeconds','切源等待时间','起播超过该时间未成功就试下一个源',
    [[5,'5 秒'],[10,'10 秒'],[15,'15 秒'],[20,'20 秒'],[25,'25 秒'],[30,'30 秒']],
    s.sourceTimeoutSeconds||5);
  html+=choiceCard('bufferSeconds','播放缓冲','弱网卡顿可调大，换台后生效',
    [[5,'5 秒'],[10,'10 秒'],[20,'20 秒'],[30,'30 秒']], s.bufferSeconds||5);
  html+='<div class="group-title">界面</div>';
  html+=switchCard('uiScaleAuto','界面缩放自动适配','按屏幕宽度自动算字号，关掉后可手动调');
  if(s.uiScaleAuto===false){
    html+=rangeCard('uiScale','界面缩放比例','电视上字太小看不全就调大',0.8,2.5,0.05,
      (typeof s.uiScale==='number'?s.uiScale:1),2,'x');
  }
  html+='<div class="set-hint">修改即时生效并自动保存。换台跳过关键词、声音均衡器细调等请在设备上打开设置面板。</div>';
  el('list').innerHTML=html;
}

// ==================== 系统 ====================
function renderSystem(){
  var s=state.settings||{}, desktop=s.isDesktop!==false;
  var html='';
  if(desktop){
    html+='<div class="group-title">桌面端</div>';
    html+=switchCard('alwaysOnTop','窗口置顶','窗口始终在最前，快捷键不被别的窗口抢走');
    if(s.isWindows)html+=switchCard('closeToTray','✕ 最小化到托盘','点关闭按钮缩到托盘继续播放，托盘图标左键恢复');
    html+=switchCard('launchAtStartup','开机启动','登录系统后自动启动');
    html+=switchCard('startFullscreen','启动全屏','只在程序启动时生效一次');
  }
  html+='<div class="group-title">播放与网络</div>';
  html+=switchCard('showClock','显示时间','右上角一直显示实时系统时间');
  html+=switchCard('webEnabled','网页直播支持','关闭后重启不再加载 WebView2；不支持的系统可用它规避出错');
  html+=switchCard('autoReloadStall','失败自动重载','网页卡死自动重载、直播失败自动重试；次数用尽提示链接失效');
  html+=choiceCard('retryTimes','自动重试次数','每个频道连续失败达到次数后判定链接失效',
    [[3,'3 次'],[5,'5 次'],[10,'10 次']], s.retryTimes||3);
  var dlnaOn=s.dlnaEnabled!==false;
  var dlnaSub=dlnaOn
    ? ('已开启'+(s.dlnaName?'：'+esc(s.dlnaName):'')+'。手机需与电脑同一局域网，防火墙要放行本程序')
    : '未开启：手机投屏搜不到本机；开启后需允许防火墙访问';
  html+=switchCard('dlnaEnabled','DLNA 投屏接收',dlnaSub);
  html+=choiceCard('castEndWaitSeconds','投屏结束后','等待期间发送端连播（下一集）可直接接上；「一直等」停在等待画面',
    [[0,'立即'],[60,'1 分'],[300,'5 分'],[600,'10 分'],[-1,'一直等']], s.castEndWaitSeconds||0);
  html+='<div class="group-title">手机管理</div>';
  html+=switchCard('remoteAdminEnabled','扫码管理开关','关掉后这个网页会立即断开；一般保持开启');
  html+='<div class="set-hint">导出网页诊断日志、换台跳过关键词等只能在设备上操作。</div>';
  el('list').innerHTML=html;
}

// ==================== 说明 ====================
function renderHelp(){
  el('list').innerHTML='<div class="group-title">怎么用</div>'
    +'<div class="card"><div class="help-card">'
    +'<div class="help-item"><div class="help-k">1</div><div class="help-v"><b>在同一个 Wi-Fi 下</b>用手机浏览器打开这个地址：<a href="http://'+location.host+'" class="help-link">http://'+location.host+'</a>，或者扫播放器里的二维码</div></div>'
    +'<div class="help-item"><div class="help-k">2</div><div class="help-v"><b>直播源</b>：点右下角 +，粘贴 M3U / M3U8 / TXT 订阅地址；内置源只能「设为当前」，不能删改</div></div>'
    +'<div class="help-item"><div class="help-k">3</div><div class="help-v"><b>电台</b>：搜台后点「加入」进「我的电台」，可随时播放或移除；内置电台精选只能整源停用/恢复</div></div>'
    +'<div class="help-item"><div class="help-k">4</div><div class="help-v"><b>EPG 节目单</b>：切到「EPG」标签，粘贴 XMLTV 地址；设为当前后播放器每天自动拉一次</div></div>'
    +'<div class="help-item"><div class="help-k">5</div><div class="help-v"><b>播放 / 系统</b>：与设备上的设置面板一一对应，改完即时生效并自动保存</div></div>'
    +'</div></div>'
    +'<div class="group-title">快捷键</div>'
    +'<div class="card"><div class="help-card">'
    +'<div class="help-item"><div class="help-k">菜单</div><div class="help-v">遥控器菜单键：<b>短按</b>呼出右侧节目单 EPG 面板，<b>长按</b>呼出本管理页二维码</div></div>'
    +'<div class="help-item"><div class="help-k">Alt+W</div><div class="help-v">电脑键盘呼出本管理页二维码（Ctrl+W 亦可）</div></div>'
    +'<div class="help-item"><div class="help-k">Esc</div><div class="help-v">关闭面板 / 退出锁定（安卓返回键同效）</div></div>'
    +'<div class="help-item"><div class="help-k">空格</div><div class="help-v">播放 / 暂停</div></div>'
    +'<div class="help-item"><div class="help-k">F / F11</div><div class="help-v">全屏切换</div></div>'
    +'<div class="help-item"><div class="help-k">M</div><div class="help-v">静音</div></div>'
    +'<div class="help-item"><div class="help-k">C / E</div><div class="help-v">呼出频道列表 / EPG 面板</div></div>'
    +'<div class="help-item"><div class="help-k">S / R</div><div class="help-v">设置面板 / 录制切换</div></div>'
    +'</div></div>'
    +'<div class="group-title">小贴士</div>'
    +'<div class="card"><div class="help-card">'
    +'<div class="help-item"><div class="help-k">·</div><div class="help-v">安卓电视/电视盒子按遥控器 ← → ↑ ↓ OK 操作，长按 OK 呼出控制面板；底部「小窗播放」可缩成系统画中画</div></div>'
    +'<div class="help-item"><div class="help-k">·</div><div class="help-v">定时关闭在设备上「退出」卡片里设置（视频/电台都生效），到点前 60 秒画面弹提示，按返回键可取消</div></div>'
    +'<div class="help-item"><div class="help-k">·</div><div class="help-v">「窗口置顶 / 开机启动 / 启动全屏 / 最小化到托盘」仅桌面端生效</div></div>'
    +'<div class="help-item"><div class="help-k">·</div><div class="help-v">EPG 每天自动拉取一次，断网时用上次缓存；切换 EPG 源需先设为当前</div></div>'
    +'</div></div>';
}

// ==================== 直播源/EPG 增删改 ====================
function setType(t){
  editType=t;
  el('t-url').className=t==='url'?'on':'';
  el('t-local').className=t==='local'?'on':'';
  el('url-label').textContent=t==='url'?'地址 URL':'本地文件完整路径';
}
function openEdit(id){
  editing=id||null;
  var items=tab==='pl'?state.playlists:state.epgs;
  var it=findById(items,id);
  el('sheet-title').textContent=it?'编辑':'添加'+(tab==='pl'?'直播源':'EPG');
  el('type-wrap').style.display=tab==='pl'?'block':'none';
  el('f-name').value=it?it.name:'';
  el('f-url').value=it?it.url:'';
  if(tab==='pl')setType(it?(it.type||'url'):'url');
  el('mask').className='sheet-mask show';
}
function closeEdit(){el('mask').className='sheet-mask'}
function persist(){
  return fetch('/api/snapshot',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(state)});
}
function saveEdit(){
  var name=el('f-name').value.trim();
  var url=el('f-url').value.trim();
  if(!name||!url){toast('请填写名称和地址');return}
  var items=tab==='pl'?state.playlists:state.epgs;
  var it=findById(items,editing);
  if(it){it.name=name;it.url=url;if(tab==='pl')it.type=editType;}
  else{
    var id=String(Date.now())+String(Math.floor(Math.random()*1000));
    if(tab==='pl'){state.playlists.push({id:id,name:name,url:url,type:editType,format:'unknown',addedAt:new Date().toISOString(),radio:false});
      if(!state.currentPlaylistId)state.currentPlaylistId=id;}
    else{state.epgs.push({id:id,name:name,url:url,addedAt:new Date().toISOString()});
      if(!state.currentEpgId)state.currentEpgId=id;}
  }
  persist().then(function(){closeEdit();load();toast('已保存')});
}
function delItem(id){
  if(!confirm('确定删除？'))return;
  if(tab==='pl'){state.playlists=state.playlists.filter(function(x){return x.id!==id});if(state.currentPlaylistId===id)state.currentPlaylistId=null;}
  else{state.epgs=state.epgs.filter(function(x){return x.id!==id});if(state.currentEpgId===id)state.currentEpgId=null;}
  persist().then(function(){load();toast('已删除')});
}
function selectItem(id){
  if(tab==='pl')state.currentPlaylistId=id;else state.currentEpgId=id;
  persist().then(function(){
    load();
    fetch('/api/refresh',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({kind:tab==='pl'?'playlists':'epgs'})});
    toast('已切换');
  });
}
function refreshItem(){
  fetch('/api/refresh',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({kind:tab==='pl'?'playlists':'epgs'})});
  toast('已通知电脑刷新');
}
function copyItem(id){
  var items=tab==='pl'?state.playlists:state.epgs;
  var it=findById(items,id);
  var text=it.name+'\n'+it.url;
  if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(text).then(function(){toast('名称和地址已复制')})}
  else{var ta=document.createElement('textarea');ta.value=text;document.body.appendChild(ta);ta.select();document.execCommand('copy');ta.remove();toast('已复制')}
}
var toastTimer;
function toast(msg){var t=el('toast');t.textContent=msg;t.style.display='block';clearTimeout(toastTimer);toastTimer=setTimeout(function(){t.style.display='none'},1800)}
load();
</script>
</body>
</html>
''';
