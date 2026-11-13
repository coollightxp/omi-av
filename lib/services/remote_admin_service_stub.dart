/// Web 管理服务回调（只使用基础类型，保证 Web 占位实现也能引用）
class RemoteAdminHooks {
  /// 返回当前全部配置快照：
  /// {playLists:[...], currentPlaylistId, epgs:[...], currentEpgId}
  final Future<Map<String, dynamic>> Function() getSnapshot;

  /// 手机端保存全量配置（增删改后的列表 + 当前选中项）
  final Future<void> Function(Map<String, dynamic> data) applySnapshot;

  /// 请求重新拉取：kind = playlists / epgs / radio
  final Future<void> Function(String kind) refresh;

  /// 在线电台目录搜索（仅原生实现使用）
  final Future<List<Map<String, dynamic>>> Function(String query, String tag)?
      searchRadio;
  final Future<void> Function(Map<String, dynamic> station)? addRadio;
  final Future<void> Function(String stationId)? removeRadio;
  final Future<void> Function(String stationId)? playRadio;
  final Future<void> Function(String playlistId)? selectPlaylist;
  final Future<void> Function()? restoreBuiltinRadio;

  /// 重新抓一次内置节目单（央视网），返回提示文案
  final Future<String> Function()? updateBuiltinEpg;

  /// 内置节目单状态：{count, at}
  final Future<Map<String, dynamic>> Function()? builtinEpgInfo;

  /// 内置清单（央视频道 / 电台精选）状态：{cctv:{...}, radio:{...}}
  final Future<Map<String, dynamic>> Function()? builtinInfo;

  /// 手动更新内置清单：kind = cctv / radio，返回 {ok, message}
  final Future<Map<String, dynamic>> Function(String kind)? updateBuiltin;

  /// 设置内置清单自动检查间隔（天）：0 关闭 / 7 每周 / 30 每月
  final Future<void> Function(String kind, int days)? setBuiltinInterval;

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
    this.builtinInfo,
    this.updateBuiltin,
    this.setBuiltinInterval,
  });
}

/// Web 端占位实现（局域网管理服务仅原生平台可用）
class RemoteAdminService {
  bool get isRunning => false;
  String get endpoint => '';

  Future<void> start({required RemoteAdminHooks hooks}) async {}

  void stop() {}
}
