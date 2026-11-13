import 'dart:convert' show base64Decode, base64Encode, jsonDecode, jsonEncode, utf8;
import 'dart:io';
import 'dart:async';

import 'package:fl_charset/fl_charset.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/channel.dart';
import '../models/epg_program.dart';
import '../models/epg_source.dart';
import '../models/playlist_source.dart';
import 'builtin_catalog.dart';
import 'builtin_epg.dart';
import 'playlist_parser.dart';
import 'radio_library.dart';
import 'xmltv_epg_parser.dart';

/// 播放列表与 EPG 源管理服务
/// 负责：源的增删改查、本地持久化、网络拉取与解析
class SourceManager {
  static const String _playlistKey = 'omi_playlists';
  static const String _currentPlaylistKey = 'omi_current_playlist';
  static const String _epgKey = 'omi_epgs';
  static const String _currentEpgKey = 'omi_current_epg';
  /// 用户删掉内置源后置 true，不再自动补回（设置页可手动恢复）
  static const String _builtinRemovedKey = 'omi_builtin_radio_removed';
  /// 用户删掉内置 EPG 后置 true，不再自动补回
  static const String _builtinEpgRemovedKey = 'omi_builtin_epg_removed';

  // EPG 每日缓存：拉取后序列化到 SharedPreferences，24h 内复用，
  // 避免每次打开都联网（EPG 一天内几乎不变）。
  // 缓存 key = omi_epg_cache_${epgId} / omi_epg_cache_time_${epgId}
  static String _cacheKey(String id) => 'omi_epg_cache_$id';
  static String _cacheTimeKey(String id) => 'omi_epg_cache_time_$id';
  static const Duration _epgCacheTtl = Duration(hours: 24);

  List<PlaylistSource> _playlists = [];
  List<EpgSource> _epgs = [];
  String? _currentPlaylistId;
  String? _currentEpgId;

  // 缓存解析后的数据
  List<ChannelCategory> _cachedChannels = [];
  Map<String, List<EpgProgram>> _cachedEpg = {};
  /// EPG 频道 id -> 显示名列表
  Map<String, List<String>> _cachedEpgChannelNames = {};
  /// EPG 频道 id -> 台标地址
  Map<String, String> _cachedEpgChannelIcons = {};
  bool _channelsLoaded = false;
  bool _epgLoaded = false;
  bool _builtinRemoved = false;
  bool _builtinEpgRemoved = false;

  List<PlaylistSource> get playlists => List.unmodifiable(_playlists);
  List<EpgSource> get epgs => List.unmodifiable(_epgs);
  String? get currentPlaylistId => _currentPlaylistId;
  String? get currentEpgId => _currentEpgId;
  List<ChannelCategory> get cachedChannels => _cachedChannels;
  Map<String, List<EpgProgram>> get cachedEpg => _cachedEpg;
  bool get channelsLoaded => _channelsLoaded;
  bool get epgLoaded => _epgLoaded;

  /// 内置电台源是否被用户删掉（设置页显示「恢复内置电台」用）
  bool get builtinRadioRemoved => _builtinRemoved;

  PlaylistSource? get currentPlaylist {
    if (_currentPlaylistId == null) return null;
    try {
      return _playlists.firstWhere((p) => p.id == _currentPlaylistId);
    } catch (_) {
      return null;
    }
  }

  EpgSource? get currentEpg {
    if (_currentEpgId == null) return null;
    try {
      return _epgs.firstWhere((e) => e.id == _currentEpgId);
    } catch (_) {
      return null;
    }
  }

  // ==================== 持久化 ====================

  Future<void> loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final playlistStr = prefs.getString(_playlistKey);
    if (playlistStr != null && playlistStr.isNotEmpty) {
      _playlists = PlaylistSource.decodeList(playlistStr);
    }
    _currentPlaylistId = prefs.getString(_currentPlaylistKey);
    _builtinRemoved = prefs.getBool(_builtinRemovedKey) == true;
    await _ensureBuiltinRadio(prefs);
    await _ensureBuiltinCctv(prefs);
    // 我的电台：库里有台就保证源列表里有对应条目
    await RadioLibrary.load();
    await ensureRadioLibrarySource();

    // 去重兜底：旧版网页保存曾把电台源重复追加进列表（一次保存多一批），
    // 这里按 id 只留第一条，用户升级上来重启即自动清干净
    if (_playlists.length > 1) {
      final seen = <String>{};
      _playlists.retainWhere((p) => seen.add(p.id));
    }

    final epgStr = prefs.getString(_epgKey);
    if (epgStr != null && epgStr.isNotEmpty) {
      _epgs = EpgSource.decodeList(epgStr);
    }
    _currentEpgId = prefs.getString(_currentEpgKey);
    _builtinEpgRemoved = prefs.getBool(_builtinEpgRemovedKey) == true;

    // 内置节目单：默认就有一个，用户一个 EPG 都没配也能看到节目表。
    // 用户删过就不再塞回来（设置页可重新加）。
    await _ensureBuiltinEpg(prefs);
  }

  /// 内置电台精选：出厂自带，排在源列表首位。
  ///
  /// 三条规则：①用户删过就不再塞回（尊重"我不要这个源"的选择）；
  /// ②已有同 id 的条目就跳过（升级/重启幂等）；③老版本升级上来的用户
  /// 列表里没有它，补一条但**不抢占当前源**，避免改动正在用的电视源。
  Future<void> _ensureBuiltinRadio(SharedPreferences prefs) async {
    if (prefs.getBool(_builtinRemovedKey) == true) return;
    if (_playlists.any((p) => p.id == PlaylistSource.builtinRadioId)) return;
    final builtin = PlaylistSource(
      id: PlaylistSource.builtinRadioId,
      name: '内置电台精选',
      url: PlaylistSource.builtinRadioAsset,
      type: PlaylistSourceType.builtin,
      format: PlaylistFormat.m3u,
      addedAt: _builtinEpoch,
    );
    _playlists.insert(0, builtin);
    await _savePlaylists();
  }

  /// 内置央视频道：规则同上，独立删除标记（删电台不影响央视，反之亦然）
  Future<void> _ensureBuiltinCctv(SharedPreferences prefs) async {
    if (prefs.getBool(_kBuiltinCctvRemovedKey) == true) return;
    if (_playlists.any((p) => p.id == PlaylistSource.builtinCctvId)) return;
    final builtin = PlaylistSource(
      id: PlaylistSource.builtinCctvId,
      name: PlaylistSource.builtinCctvName,
      url: PlaylistSource.builtinCctvAsset,
      type: PlaylistSourceType.builtin,
      format: PlaylistFormat.m3u,
      addedAt: _builtinEpoch,
    );
    // 插在电台条目之后，两者都靠前（出厂源不该埋在用户源后面）
    final idx = _playlists.indexWhere(
      (p) => p.id == PlaylistSource.builtinRadioId,
    );
    _playlists.insert(idx >= 0 ? idx + 1 : 0, builtin);
    await _savePlaylists();
    // 全新安装（没有任何当前源）：默认落到央视频道。电视是主场景，
    // 让用户开箱就能看到台，而不是先对着一个空列表找源
    if (_currentPlaylistId == null) {
      _currentPlaylistId = PlaylistSource.builtinCctvId;
      await prefs.setString(_currentPlaylistKey, _currentPlaylistId!);
    }
  }

  /// 内置 EPG：只在没有、且用户没删过时补一条。
  ///
  /// 新装用户打开 EPG 页直接就有央视节目表（不用去哪个网站找 xmltv），
  /// 老用户自己配的 EPG 不会被抢——只有当前 EPG 为空/失效时才落到内置。
  Future<void> _ensureBuiltinEpg(SharedPreferences prefs) async {
    if (_builtinEpgRemoved) return;
    var changed = false;
    if (!_epgs.any((e) => e.id == BuiltinEpg.sourceId)) {
      _epgs.insert(0, BuiltinEpg.builtinSource());
      changed = true;
    }
    final curValid =
        _currentEpgId != null && _epgs.any((e) => e.id == _currentEpgId);
    if (!curValid) {
      _currentEpgId = BuiltinEpg.sourceId;
      changed = true;
    }
    if (changed) await _saveEpgs();
  }

  /// 恢复被删除的内置节目单
  Future<void> restoreBuiltinEpg() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_builtinEpgRemovedKey, false);
    _builtinEpgRemoved = false;
    await _ensureBuiltinEpg(prefs);
  }

  /// 内置 EPG 是否被用户删掉（设置页显示「恢复」用）
  bool get builtinEpgRemoved => _builtinEpgRemoved;

  /// 取消 EPG 的本地缓存（内置节目单手动更新后要强制重解析）
  Future<void> invalidateEpgCache(String epgId) => clearEpgCache(epgId);

  /// 恢复被删除的内置源（设置页「恢复内置电台」）
  Future<void> restoreBuiltinRadio() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_builtinRemovedKey, false);
    _builtinRemoved = false;
    await _ensureBuiltinRadio(prefs);
  }

  /// 恢复被删除的内置央视频道
  Future<void> restoreBuiltinCctv() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kBuiltinCctvRemovedKey, false);
    await _ensureBuiltinCctv(prefs);
  }

  /// 读内置源字节：电台直接读 asset；央视频道优先用远程更新过的缓存
  Future<List<int>> _loadBuiltinBytes(PlaylistSource source) async {
    final (cacheKey, asset) = source.id == PlaylistSource.builtinCctvId
        ? (_kBuiltinCctvCache, PlaylistSource.builtinCctvAsset)
        : (_kBuiltinRadioCache, PlaylistSource.builtinRadioAsset);
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(cacheKey);
    if (cached != null && cached.trim().isNotEmpty) {
      return utf8.encode(cached);
    }
    final data = await rootBundle.load(asset);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  // ==================== 内置央视频道：定期更新 ====================
  // 网页型频道列表的"地址"本身长期有效（页面 URL 不随 CDN 签名变），
  // 会变的是**有没有这个台、pid 有没有换**。所以清单做成可远程更新：
  // 出厂 asset 兜底 → 到期后台拉远程 m3u → 存本地缓存 → 下次启动生效。
  static const _kBuiltinCctvCache = 'builtin_cctv_cache';
  static const _kBuiltinCctvAt = 'builtin_cctv_fetched_at';
  static const _kBuiltinCctvInterval = 'builtin_cctv_interval_days';
  static const _kBuiltinCctvRemovedKey = 'omi_builtin_cctv_removed';
  static const _kBuiltinRadioCache = 'builtin_radio_cache';
  static const _kBuiltinRadioAt = 'builtin_radio_fetched_at';
  static const _kBuiltinRadioInterval = 'builtin_radio_interval_days';

  /// 清单镜像：多 CDN 串行尝试。
  ///
  /// 注意：GitHub 仓库当前是 private，raw / jsDelivr 都拿不到（404）——
  /// 清单要真正可更新，仓库（或专门的 omi-av-lists 仓库）必须公开。
  /// 镜像顺序：jsDelivr 多入口（国内可达性好）→ GitHub raw。
  static List<String> _builtinMirrors(String repoPath) => <String>[
        'https://cdn.jsdelivr.net/gh/coollightxp/$repoPath',
        'https://fastly.jsdelivr.net/gh/coollightxp/$repoPath',
        'https://testingcf.jsdelivr.net/gh/coollightxp/$repoPath',
        'https://gcore.jsdelivr.net/gh/coollightxp/$repoPath',
        'https://raw.githubusercontent.com/coollightxp/$repoPath',
      ];

  /// 央视清单：主仓库路径 + 公开清单仓库路径（若用户后续建了就自动可用）
  static final List<String> builtinCctvMirrors = <String>[
    ..._builtinMirrors('omi-av@main/assets/cctv/cctv_live.m3u'),
    ..._builtinMirrors('omi-av-lists@main/cctv/cctv_live.m3u'),
  ];

  /// 电台清单：同上两套路径
  static final List<String> builtinRadioMirrors = <String>[
    ..._builtinMirrors('omi-av@main/assets/radio/omi_radio.m3u'),
    ..._builtinMirrors('omi-av-lists@main/radio/omi_radio.m3u'),
  ];

  /// 更新间隔（天）：0 = 关闭自动检查；默认 7 天
  Future<int> getBuiltinCctvIntervalDays() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_kBuiltinCctvInterval) ?? 7;
  }

  Future<void> setBuiltinCctvIntervalDays(int days) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kBuiltinCctvInterval, days.clamp(0, 365));
  }

  Future<DateTime?> getBuiltinCctvFetchedAt() async {
    final p = await SharedPreferences.getInstance();
    final ms = p.getInt(_kBuiltinCctvAt);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// 当前生效清单的频道数（缓存优先，否则数 asset）
  Future<int> builtinCctvChannelCount() async {
    final p = await SharedPreferences.getInstance();
    final cached = p.getString(_kBuiltinCctvCache);
    final text = cached ??
        await rootBundle.loadString(PlaylistSource.builtinCctvAsset);
    return text
        .split('\n')
        .where((l) => l.trimLeft().startsWith('#EXTINF'))
        .length;
  }

  /// 到期就后台拉一次（启动时调，失败静默）
  Future<void> maybeAutoUpdateBuiltinCctv() async {
    final days = await getBuiltinCctvIntervalDays();
    if (days <= 0) return;
    final at = await getBuiltinCctvFetchedAt();
    if (at != null &&
        DateTime.now().difference(at).inDays < days) {
      return;
    }
    await updateBuiltinCctv();
  }

  // ==================== 内置电台：定期更新（与央视频道同款） ====================

  Future<int> getBuiltinRadioIntervalDays() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_kBuiltinRadioInterval) ?? 7;
  }

  Future<void> setBuiltinRadioIntervalDays(int days) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kBuiltinRadioInterval, days.clamp(0, 365));
  }

  Future<DateTime?> getBuiltinRadioFetchedAt() async {
    final p = await SharedPreferences.getInstance();
    final ms = p.getInt(_kBuiltinRadioAt);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// 当前生效电台清单的台数（缓存优先，否则数 asset）
  Future<int> builtinRadioStationCount() async {
    final p = await SharedPreferences.getInstance();
    final cached = p.getString(_kBuiltinRadioCache);
    final text = cached ??
        await rootBundle.loadString(PlaylistSource.builtinRadioAsset);
    return text
        .split('\n')
        .where((l) => l.trimLeft().startsWith('#EXTINF'))
        .length;
  }

  /// 到期就后台拉一次（启动时调，失败静默）
  Future<void> maybeAutoUpdateBuiltinRadio() async {
    final days = await getBuiltinRadioIntervalDays();
    if (days <= 0) return;
    final at = await getBuiltinRadioFetchedAt();
    if (at != null && DateTime.now().difference(at).inDays < days) {
      return;
    }
    await updateBuiltinRadio();
  }

  /// 拉取远程央视频道清单并落缓存。返回 (成功?, 说明)。
  Future<(bool, String)> updateBuiltinCctv({bool force = false}) async {
    // 第一优先：直接从央视网抓（不依赖任何托管仓库，站点改版也能自愈）
    final current = await _readBuiltinText(
        _kBuiltinCctvCache, PlaylistSource.builtinCctvAsset);
    final (scraped, msg, text) = await BuiltinCatalog.buildCctvList(current);
    if (scraped && text != null) {
      await _storeBuiltinList(
        cacheKey: _kBuiltinCctvCache,
        atKey: _kBuiltinCctvAt,
        sourceId: PlaylistSource.builtinCctvId,
        text: text,
      );
      return (true, msg);
    }
    // 兜底：抓取失败（网络限制 / 站点大改）时，仍可拉预生成的清单
    final (ok, mirrorMsg) = await _updateBuiltinList(
      mirrors: builtinCctvMirrors,
      cacheKey: _kBuiltinCctvCache,
      atKey: _kBuiltinCctvAt,
      sourceId: PlaylistSource.builtinCctvId,
      unit: '频道',
    );
    if (ok) return (true, mirrorMsg);
    return (false, '$msg；备用清单也不可达（$mirrorMsg）');
  }

  /// 读当前生效的内置清单文本（缓存优先，否则 asset）
  Future<String> _readBuiltinText(String cacheKey, String asset) async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(cacheKey);
    if (cached != null && cached.trim().isNotEmpty) return cached;
    try {
      return await rootBundle.loadString(asset);
    } catch (_) {
      return '#EXTM3U\n';
    }
  }

  /// 落缓存 + 当前正在用时立刻重建频道列表
  Future<void> _storeBuiltinList({
    required String cacheKey,
    required String atKey,
    required String sourceId,
    required String text,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(cacheKey, text);
    await prefs.setInt(atKey, DateTime.now().millisecondsSinceEpoch);
    if (_currentPlaylistId == sourceId) {
      _channelsLoaded = false;
      unawaited(loadChannels());
    }
  }

  /// 拉取远程内置电台清单并落缓存。返回 (成功?, 说明)。
  Future<(bool, String)> updateBuiltinRadio({bool force = false}) async {
    // 先从在线电台目录增量补台（只加不删）；失败再拉预生成的清单
    final current = await _readBuiltinText(
        _kBuiltinRadioCache, PlaylistSource.builtinRadioAsset);
    final (ok, msg, text) = await BuiltinCatalog.buildRadioList(current);
    if (ok && text != null) {
      await _storeBuiltinList(
        cacheKey: _kBuiltinRadioCache,
        atKey: _kBuiltinRadioAt,
        sourceId: PlaylistSource.builtinRadioId,
        text: text,
      );
      return (true, msg);
    }
    if (ok) return (true, msg); // 没有新台，也算成功
    final (mOk, mMmsg) = await _updateBuiltinList(
      mirrors: builtinRadioMirrors,
      cacheKey: _kBuiltinRadioCache,
      atKey: _kBuiltinRadioAt,
      sourceId: PlaylistSource.builtinRadioId,
      unit: '个台',
    );
    if (mOk) return (true, mMmsg);
    return (false, '$msg；备用清单也不可达（$mMmsg）');
  }

  /// 通用拉取：逐镜像串行尝试（jsDelivr 国内可达性好，raw 兜底），
  /// 每个镜像 15 秒超时。校验三条，避免把一个坏文件覆盖掉能用的清单：
  /// ① 含 #EXTINF ② 至少 10 条 ③ 链接多数是 webview:// 或 http(s)
  Future<(bool, String)> _updateBuiltinList({
    required List<String> mirrors,
    required String cacheKey,
    required String atKey,
    required String sourceId,
    required String unit,
  }) async {
    for (final url in mirrors) {
      try {
        final resp = await http.get(
          Uri.parse(url),
          headers: {'User-Agent': _uaBox, 'Accept': '*/*'},
        ).timeout(const Duration(seconds: 15));
        if (resp.statusCode != 200) continue;
        final text = utf8.decode(resp.bodyBytes, allowMalformed: true);
        final count = text
            .split('\n')
            .where((l) => l.trimLeft().startsWith('#EXTINF'))
            .length;
        final links = text
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty && !l.startsWith('#'))
            .toList();
        final good = links.where((l) =>
            l.toLowerCase().startsWith('webview://') ||
            l.toLowerCase().startsWith('http')).length;
        if (count < 10 || good < count * 0.8) continue;

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(cacheKey, text);
        await prefs.setInt(atKey, DateTime.now().millisecondsSinceEpoch);
        // 正在用这个源：立刻重建频道缓存，用户不用手动刷新
        if (_currentPlaylistId == sourceId) {
          _channelsLoaded = false;
          unawaited(loadChannels());
        }
        return (true, '已更新到 $count $unit');
      } catch (_) {
        // 换下一个镜像
      }
    }
    return (false, '拉取失败（清单仓库未公开或网络不通），继续用本地清单');
  }

  /// 确保「我的电台」源存在（在网上目录加了第一个台时调用）
  Future<void> ensureRadioLibrarySource() async {
    if (RadioLibrary.isEmpty) return;
    if (_playlists.any((p) => p.id == PlaylistSource.radioLibraryId)) return;
    _playlists.add(PlaylistSource(
      id: PlaylistSource.radioLibraryId,
      name: RadioLibrary.categoryName,
      // 不是真实地址，只用于列表展示与「复制」提示
      url: 'local://my-radio',
      type: PlaylistSourceType.radioLibrary,
      format: PlaylistFormat.m3u,
      addedAt: DateTime.now(),
    ));
    await _savePlaylists();
  }

  /// 我的电台内容变化后刷新：当前源是它时重建频道缓存
  Future<void> reloadRadioLibrary() async {
    await ensureRadioLibrarySource();
    if (_currentPlaylistId != PlaylistSource.radioLibraryId) return;
    _cachedChannels = RadioLibrary.buildCategories();
    _channelsLoaded = true;
  }

  /// 固定时间戳：内置源不随重启变动 addedAt，避免每次重建都改排序
  static final DateTime _builtinEpoch = DateTime(2025, 11, 1);

  Future<void> _savePlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_playlistKey, PlaylistSource.encodeList(_playlists));
    if (_currentPlaylistId != null) {
      await prefs.setString(_currentPlaylistKey, _currentPlaylistId!);
    } else {
      await prefs.remove(_currentPlaylistKey);
    }
  }

  Future<void> _saveEpgs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_epgKey, EpgSource.encodeList(_epgs));
    if (_currentEpgId != null) {
      await prefs.setString(_currentEpgKey, _currentEpgId!);
    } else {
      await prefs.remove(_currentEpgKey);
    }
  }

  // ==================== 播放列表管理 ====================

  /// 添加播放列表源
  Future<void> addPlaylist(PlaylistSource source) async {
    _playlists.add(source);
    await _savePlaylists();
  }

  /// 删除播放列表源
  Future<void> removePlaylist(String id) async {
    final wasBuiltin =
        _playlists.any((p) => p.id == id && p.isBuiltin);
    _playlists.removeWhere((p) => p.id == id);
    if (_currentPlaylistId == id) {
      _currentPlaylistId = null;
      _cachedChannels = [];
      _channelsLoaded = false;
    }
    await _savePlaylists();
    // 内置源删掉后打标记，下次启动不再自动补回（两个内置源各自独立）
    if (wasBuiltin) {
      final prefs = await SharedPreferences.getInstance();
      if (id == PlaylistSource.builtinCctvId) {
        await prefs.setBool(_kBuiltinCctvRemovedKey, true);
      } else {
        _builtinRemoved = true;
        await prefs.setBool(_builtinRemovedKey, true);
      }
    }
  }

  /// 编辑播放列表源（名称/地址/类型）；地址变化后需重新加载频道
  Future<void> updatePlaylist(PlaylistSource source) async {
    final idx = _playlists.indexWhere((p) => p.id == source.id);
    if (idx < 0) return;
    _playlists[idx] = source;
    await _savePlaylists();
  }

  /// 全量替换（Web 管理端保存）：返回当前选中项是否仍存在
  Future<bool> replacePlaylists(
      List<PlaylistSource> list, String? currentId) async {
    // 同 id 只留一条：网页端/外部调用者发来的列表不信任，防止重复源
    // 在列表里越攒越多（历史上网页保存一次多一批电台源的教训）
    final seen = <String>{};
    _playlists = List.of(list)..retainWhere((p) => seen.add(p.id));
    _currentPlaylistId =
        _playlists.any((p) => p.id == currentId) ? currentId : null;
    await _savePlaylists();
    return _currentPlaylistId != null;
  }

  /// 选择当前使用的播放列表
  Future<void> selectPlaylist(String? id) async {
    _currentPlaylistId = id;
    await _savePlaylists();
  }

  /// 加载并解析当前播放列表的频道
  Future<List<ChannelCategory>> loadChannels() async {
    final source = currentPlaylist;
    if (source == null) {
      _cachedChannels = [];
      _channelsLoaded = true;
      return [];
    }

    try {
      // 我的电台：内容在 prefs 里，直接构建分类，不读文件/网络
      if (source.type == PlaylistSourceType.radioLibrary) {
        _cachedChannels = RadioLibrary.buildCategories();
        _channelsLoaded = true;
        return _cachedChannels;
      }
      final List<int> bytes;
      if (source.type == PlaylistSourceType.builtin) {
        bytes = await _loadBuiltinBytes(source);
      } else if (source.type == PlaylistSourceType.local) {
        bytes = await File(source.url).readAsBytes();
      } else {
        bytes = await _fetchPlaylistBytes(source.url);
      }

      final content = _decodePlaylistBytes(bytes);
      // 三级解析：m3u/txt 直接解析；HTML 聚合页提取 data-copy 接口地址；
      // TVBox 配置 JSON（lives）/多仓 JSON（urls）递归展开合并
      var cats =
          await _resolveContent(content, source.url, 2, {source.url});
      // 内置电台精选整份都是电台流：按地址/分组猜类型会漏判（音频 HLS
      // 的 m3u8 会落到 tv），必须整体强制 radio——否则这 60 个台会漏进
      // 电视域，左侧两个标签看到一模一样的列表。
      // 内置央视频道相反：全是 webview 网页频道，按正常判定即可
      if (source.id == PlaylistSource.builtinRadioId) {
        cats = [
          for (final c in cats)
            c.copyWith(
              channels: [
                for (final ch in c.channels)
                  ch.channelType == ChannelType.radio
                      ? ch
                      : ch.copyWith(channelType: ChannelType.radio),
              ],
            ),
        ];
      }
      // 导入过滤（方案 12.3）：只留 group-title/频道名命中关键字的频道
      _cachedChannels = applyGroupFilter(cats, source.groupFilter);
      _channelsLoaded = true;

      // 更新最后更新时间
      final idx = _playlists.indexWhere((p) => p.id == source.id);
      if (idx >= 0) {
        _playlists[idx] = source.copyWith(lastUpdated: DateTime.now());
        await _savePlaylists();
      }
    } catch (e) {
      _cachedChannels = [];
      _channelsLoaded = true;
      rethrow;
    }
    return _cachedChannels;
  }

  /// 拉取网络播放列表字节：
  /// 国内盒子生态源（DIYP/影视仓）面向 okhttp 客户端，浏览器 UA 反而会被
  /// 广告劫持页拦截；个别源又只认浏览器。策略：先用 okhttp，
  /// 若返回内容是 HTML 广告页则换浏览器 UA 重试一次。
  ///
  /// 实测存在**按 UA 分流**的源（302 到不同地址）：`okhttp*` 给真源，
  /// 其它（含 Dart/浏览器/空）一律跳到推广落地页。所以按 okhttp → 浏览器
  /// → VLC 三级依次试；拿到 HTML 也先留着当兜底（影视仓类的聚合分享页
  /// 本来就是 HTML，不能直接判死）。
  static const _uaBox = 'okhttp/3.15';
  static const _uaBrowser =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  static const _uaVlc = 'VLC/3.0.18 LibVLC/3.0.18';

  static bool _looksLikeHtmlBytes(List<int> bytes) {
    final text = utf8
        .decode(bytes.take(400).toList(), allowMalformed: true)
        .trimLeft()
        .toLowerCase();
    return text.startsWith('<!doctype html') ||
        text.startsWith('<html') ||
        text.startsWith('<!--') ||
        text.startsWith('<head') ||
        text.startsWith('<meta');
  }

  Future<List<int>> _fetchPlaylistBytes(String url,
      {Duration timeout = const Duration(seconds: 60)}) async {
    Future<List<int>> get(String ua) async {
      final resp = await http
          .get(
            Uri.parse(url),
            headers: {'User-Agent': ua, 'Accept': '*/*'},
          )
          .timeout(timeout);
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      return resp.bodyBytes;
    }

    List<int>? htmlFallback;
    Object? lastError;
    for (final ua in const [_uaBox, _uaBrowser, _uaVlc]) {
      try {
        final bytes = await get(ua);
        if (!_looksLikeHtmlBytes(bytes)) return bytes;
        htmlFallback ??= bytes;
      } catch (e) {
        lastError = e;
      }
    }
    if (htmlFallback != null) return htmlFallback;
    throw Exception('源不可用，三种客户端标识都被拒绝（$lastError）');
  }

  /// 源诊断：把"服务器到底怎么响应、最后给了什么、能解出几个台"
  /// 摊开给用户看。按 UA 分流/跳到广告页/编码不对 这类问题一眼可辨，
  /// 不必再靠猜。
  Future<List<String>> diagnoseSource(String url) async {
    final lines = <String>[];
    final target = url.trim();
    if (target.isEmpty) return ['地址为空'];
    lines.add('地址：$target');

    for (final entry in const {
      'okhttp': _uaBox,
      '浏览器': _uaBrowser,
      'VLC': _uaVlc,
    }.entries) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 12)
        ..userAgent = entry.value;
      try {
        var current = Uri.parse(target);
        final hops = <String>[];
        int code = 0;
        var redirects = 0;
        for (var i = 0; i < 6; i++) {
          final req = await client.getUrl(current);
          req.headers.set('User-Agent', entry.value);
          req.followRedirects = false;
          final resp = await req.close().timeout(const Duration(seconds: 15));
          code = resp.statusCode;
          if (code >= 300 && code < 400) {
            final loc = resp.headers.value('location') ?? '';
            await resp.drain<void>();
            if (loc.isEmpty) break;
            current = current.resolve(loc);
            redirects++;
            hops.add('→$current');
            continue;
          }
          final bytes = await resp
              .fold<List<int>>(<int>[], (a, b) => a..addAll(b))
              .timeout(const Duration(seconds: 20));
          final html = _looksLikeHtmlBytes(bytes);
          final text = _decodePlaylistBytes(bytes);
          String parsed = '';
          try {
            final cats = await _resolveContent(text, current.toString(), 1, {});
            final n = cats.fold<int>(0, (s, c) => s + c.channels.length);
            final names = cats
                .expand((c) => c.channels)
                .take(3)
                .map((c) => c.name)
                .join('、');
            parsed = '解析出 $n 个频道${names.isEmpty ? '' : '（$names…）'}';
          } catch (e) {
            parsed = '解析失败：$e';
          }
          lines.add('[${entry.key}] HTTP $code'
              '${redirects > 0 ? ' · $redirects 次跳转${hops.join('')}' : ''}'
              ' · ${bytes.length} 字节'
              '${html ? ' · HTML 页面' : ''}');
          lines.add('    $parsed');
          break;
        }
        if (redirects >= 6 || code == 0) {
          lines.add('[${entry.key}] 跳转过多或连接失败：${hops.join('')}');
        }
      } catch (e) {
        lines.add('[${entry.key}] 请求失败：$e');
      } finally {
        client.close(force: true);
      }
    }
    lines.add('');
    lines.add('提示：若只有 okhttp 有结果，说明该源按 UA 分流，'
        '正常播放时会自动用它；若结果全是 HTML/0 频道，该地址本身没有直播源。');
    return lines;
  }

  /// 播放列表编码自动识别：
  /// 1. BOM：UTF-8(EF BB BF) / UTF-16 LE/BE
  /// 2. 严格 UTF-8 解码成功 → UTF-8（GBK 中文双字节几乎不可能通过 UTF-8 校验）
  /// 3. 失败 → GBK/GB18030（国内 DIYP/盒子分享源常见 ANSI 编码）
  /// 4. 都失败 → 宽松 UTF-8（不丢数据，乱码字符替换显示）
  static String _decodePlaylistBytes(List<int> bytes) {
    if (bytes.isEmpty) return '';
    // UTF-8 BOM
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3));
    }
    try {
      return utf8.decode(bytes);
    } catch (_) {
      try {
        return gbk.decode(bytes);
      } catch (_) {
        return utf8.decode(bytes, allowMalformed: true);
      }
    }
  }

  // ==================== 内容递归解析 ====================
  // 盒子生态常见三级结构：
  // 1) HTML 聚合分享页（影视仓等）：卡片带 data-copy="接口地址" data-name="名称"
  // 2) TVBox 配置 JSON（lives 数组，type=0 为直链）/ 多仓 JSON（urls 数组）
  // 3) m3u / TXT 直播源（PlaylistParser 处理）
  // 递归展开并合并所有频道路径；深度限制 + 已访问集合防自引用死循环。

  static final _htmlTagRe = RegExp(r'<[^>]+>');
  static final _copyAttrRe =
      RegExp('data-copy\\s*=\\s*["\']([^"\']+)["\']');

  Future<List<ChannelCategory>> _resolveContent(
      String content, String url, int depth, Set<String> visited) async {
    final t = content.trimLeft();
    final lower = t.toLowerCase();
    if (lower.startsWith('<')) {
      if (depth <= 0) return const [];
      return _resolveHtmlPage(content, depth, visited);
    }
    if (t.startsWith('{')) {
      if (depth <= 0) return const [];
      return _resolveTvboxConfig(content, depth, visited);
    }
    final format = PlaylistParser.detectFormat(content, url);
    return PlaylistParser.parse(content, format);
  }

  /// 导入分组过滤（方案 12.3）：groupFilter 逗号分隔多个关键字，
  /// 不区分大小写、包含即命中；group-title 或频道名命中任一关键字
  /// 的频道保留。过滤后空分类剔除；关键字为空则原样返回。
  static List<ChannelCategory> applyGroupFilter(
      List<ChannelCategory> cats, String groupFilter) {
    final keys = groupFilter
        .split(RegExp(r'[,，;；]'))
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toList();
    if (keys.isEmpty) return cats;
    bool hit(Channel ch) {
      final name = ch.name.toLowerCase();
      final group = ch.groupTitle.toLowerCase();
      for (final k in keys) {
        if (name.contains(k) || group.contains(k)) return true;
      }
      return false;
    }

    return [
      for (final c in cats)
        if (c.channels.any(hit))
          ChannelCategory(
            id: c.id,
            name: c.name,
            channels: c.channels.where(hit).toList(),
          ),
    ];
  }

  /// HTML 聚合页：提取所有 data-copy 接口地址，逐个递归解析
  Future<List<ChannelCategory>> _resolveHtmlPage(
      String content, int depth, Set<String> visited) async {
    final results = <List<ChannelCategory>>[];
    for (final m in _htmlTagRe.allMatches(content)) {
      final tag = m.group(0)!;
      if (!tag.contains('data-copy')) continue;
      final c = _copyAttrRe.firstMatch(tag);
      if (c == null) continue;
      final cats = await _resolveUrl(c.group(1)!, depth - 1, visited);
      if (cats.isNotEmpty) results.add(cats);
    }
    return _mergeCategories(results);
  }

  /// TVBox 配置 JSON（lives）/ 多仓 JSON（urls）：展开子地址递归解析。
  /// lives 中 type=0 才是直链列表（1/2/3 为代理/jar 类型无法直连）；
  /// clan:// 等本地协议直接跳过
  Future<List<ChannelCategory>> _resolveTvboxConfig(
      String content, int depth, Set<String> visited) async {
    dynamic json;
    try {
      json = jsonDecode(content);
    } catch (_) {
      return const [];
    }
    if (json is! Map) return const [];
    final results = <List<ChannelCategory>>[];

    final lives = json['lives'];
    if (lives is List) {
      for (final live in lives) {
        if (live is! Map) continue;
        if ('${live['type']}' != '0') continue;
        final u = live['url'];
        if (u is! String) continue;
        final cats = await _resolveUrl(u, depth - 1, visited);
        if (cats.isNotEmpty) results.add(cats);
      }
    }

    final urls = json['urls'];
    if (urls is List) {
      for (final e in urls) {
        if (e is! Map) continue;
        final u = e['url'];
        if (u is! String) continue;
        final cats = await _resolveUrl(u, depth - 1, visited);
        if (cats.isNotEmpty) results.add(cats);
      }
    }
    return _mergeCategories(results);
  }

  /// 拉取并解析单个子地址（15 秒超时，单个失败不影响其它）
  Future<List<ChannelCategory>> _resolveUrl(
      String url, int depth, Set<String> visited) async {
    final u = url.trim();
    if (u.isEmpty ||
        visited.contains(u) ||
        !(u.startsWith('http://') || u.startsWith('https://'))) {
      return const [];
    }
    visited.add(u);
    try {
      final bytes = await _fetchPlaylistBytes(u,
          timeout: const Duration(seconds: 15));
      final content = _decodePlaylistBytes(bytes);
      final cats = await _resolveContent(content, u, depth, visited);
      if (cats.isNotEmpty) return cats;
      // 多仓里的条目常是「目录地址」（以 / 结尾，直接访问只是一张
      // 网页门户），TVBox 客户端约定自己拼配置文件。按惯例挨个试：
      // index.json → demo.json → config.json，命中第一个有频道的即止
      if (u.endsWith('/')) {
        for (final f in const ['index.json', 'demo.json', 'config.json']) {
          final sub = '$u$f';
          if (visited.contains(sub)) continue;
          visited.add(sub);
          try {
            final b = await _fetchPlaylistBytes(sub,
                timeout: const Duration(seconds: 12));
            final r = await _resolveContent(
                _decodePlaylistBytes(b), sub, depth, visited);
            if (r.isNotEmpty) return r;
          } catch (_) {
            // 该文件名不存在：继续试下一个
          }
        }
      }
      return cats;
    } catch (_) {
      return const [];
    }
  }

  /// 按分类名合并多路解析结果（同名频道交由 PlaylistParser 的合并键处理）
  List<ChannelCategory> _mergeCategories(
      Iterable<List<ChannelCategory>> lists) {
    final merged = <String, List<Channel>>{};
    final order = <String>[];
    for (final list in lists) {
      for (final c in list) {
        if (merged.containsKey(c.name)) {
          // 按频道 ID 去重：多源重复的同名同地址频道只保留一个，
          // 避免列表里一大片同时显示选中态
          for (final ch in c.channels) {
            final idx = merged[c.name]!
                .indexWhere((e) => e.id == ch.id);
            if (idx < 0) {
              merged[c.name]!.add(ch);
            } else {
              final existing = merged[c.name]![idx];
              for (final u in ch.streamUrls) {
                if (!existing.streamUrls.contains(u)) {
                  existing.streamUrls.add(u);
                }
              }
            }
          }
        } else {
          merged[c.name] = List<Channel>.from(c.channels);
          order.add(c.name);
        }
      }
    }
    return [
      for (final name in order)
        ChannelCategory(id: name, name: name, channels: merged[name]!)
    ];
  }

  // ==================== EPG 管理 ====================

  /// 添加 EPG 源
  Future<void> addEpg(EpgSource source) async {
    _epgs.add(source);
    await _saveEpgs();
  }

  /// 删除 EPG 源
  Future<void> removeEpg(String id) async {
    _epgs.removeWhere((e) => e.id == id);
    if (_currentEpgId == id) {
      _currentEpgId = null;
      _cachedEpg = {};
      _epgLoaded = false;
    }
    // 内置节目单被删：记下来，重启不再自动补回（设置页可恢复）
    if (id == BuiltinEpg.sourceId) {
      _builtinEpgRemoved = true;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_builtinEpgRemovedKey, true);
    }
    await _saveEpgs();
  }

  /// 选择当前使用的 EPG
  Future<void> selectEpg(String? id) async {
    _currentEpgId = id;
    await _saveEpgs();
  }

  /// 编辑 EPG 源（名称/地址）
  Future<void> updateEpg(EpgSource source) async {
    final idx = _epgs.indexWhere((e) => e.id == source.id);
    if (idx < 0) return;
    _epgs[idx] = source;
    await _saveEpgs();
  }

  /// 全量替换（Web 管理端保存）
  Future<void> replaceEpgs(List<EpgSource> list, String? currentId) async {
    _epgs = list;
    _currentEpgId = list.any((e) => e.id == currentId) ? currentId : null;
    await _saveEpgs();
  }

  /// 加载并解析当前 EPG 数据。
  /// - 24h 内已拉取过同一 EPG 源 → 直接读 SharedPreferences 缓存，
  ///   跳过联网；
  /// - 超过 24h → 联网拉取，成功后更新缓存；
  /// - 联网失败但有旧缓存 → fallback 到缓存（断网时也能看到节目单）
  Future<Map<String, List<EpgProgram>>> loadEpg() async {
    final source = currentEpg;
    if (source == null) {
      _cachedEpg = {};
      _epgLoaded = true;
      return {};
    }

    // 内置节目单：正文是 App 自己从央视网抓来拼好的 XMLTV，不走网络
    if (source.url == BuiltinEpg.localUrl) {
      return _loadBuiltinEpg(source.id);
    }

    final prefs = await SharedPreferences.getInstance();

    // 1. 读缓存：如果还在有效期内直接用
    final cacheTimeMs = prefs.getInt(_cacheTimeKey(source.id));
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (cacheTimeMs != null &&
        nowMs - cacheTimeMs < _epgCacheTtl.inMilliseconds) {
      final cacheStr = prefs.getString(_cacheKey(source.id));
      if (cacheStr != null && cacheStr.isNotEmpty) {
        try {
          _applyCachedEpg(cacheStr);
          _epgLoaded = true;
          return _cachedEpg;
        } catch (_) {
          // 缓存损坏，继续联网拉取
        }
      }
    }

    try {
      final resp = await http
          .get(Uri.parse(source.url))
          .timeout(const Duration(seconds: 60));
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}');
      }

      // 支持 .gz 压缩的 EPG（按 gzip 魔数 1f 8b 判断，不依赖扩展名）。
      // 解压 + XML 解析放到后台 isolate：7 MB / 数万条节目在 UI
      // isolate 上做会把启动画面冻住好几秒
      final bytes = resp.bodyBytes;
      final parsed = await XmltvEpgParser.parseBytesAsync(bytes);
      _cachedEpg = parsed.programs;
      _cachedEpgChannelNames = parsed.channelNames;
      _cachedEpgChannelIcons = parsed.channelIcons;
      _epgLoaded = true;

      final idx = _epgs.indexWhere((e) => e.id == source.id);
      if (idx >= 0) {
        _epgs[idx] = source.copyWith(lastUpdated: DateTime.now());
        await _saveEpgs();
      }

      // 写缓存（base64 序列化，SharedPreferences 只吃字符串）
      await _writeEpgCache(source.id, parsed.programs, parsed.channelNames,
          parsed.channelIcons);
    } catch (e) {
      // 联网失败：如果有任何缓存（哪怕过期），退而用之
      final cacheStr = prefs.getString(_cacheKey(source.id));
      if (cacheStr != null && cacheStr.isNotEmpty) {
        try {
          _applyCachedEpg(cacheStr);
          _epgLoaded = true;
          return _cachedEpg;
        } catch (_) {}
      }
      _cachedEpg = {};
      _epgLoaded = true;
      rethrow;
    }
    return _cachedEpg;
  }

  /// 加载内置节目单：读 BuiltinEpg 的本地 XMLTV 缓存。
  ///
  /// 缓存为空（全新安装、或用户刚清过缓存）时现场抓一次；抓不到就返回空表
  /// 但不抛错——内置项挂掉不该弹一个「EPG 加载失败」，界面上只是没节目。
  Future<Map<String, List<EpgProgram>>> _loadBuiltinEpg(String id) async {
    var text = await BuiltinEpg.readCache();
    if (text == null || text.trim().isEmpty) {
      try {
        final (ok, msg) = await BuiltinEpg.refresh(force: true);
        if (!ok) debugPrintEpg('[内置EPG] $msg');
      } catch (e) {
        debugPrintEpg('[内置EPG] $e');
      }
      text = await BuiltinEpg.readCache();
    }
    if (text == null || text.trim().isEmpty) {
      _cachedEpg = {};
      _cachedEpgChannelNames = {};
      _cachedEpgChannelIcons = {};
      _epgLoaded = true;
      return _cachedEpg;
    }

    final parsed = await XmltvEpgParser.parseBytesAsync(utf8.encode(text));
    _cachedEpg = parsed.programs;
    _cachedEpgChannelNames = parsed.channelNames;
    _cachedEpgChannelIcons = parsed.channelIcons;
    _epgLoaded = true;

    final idx = _epgs.indexWhere((e) => e.id == id);
    if (idx >= 0) {
      _epgs[idx] = _epgs[idx].copyWith(lastUpdated: DateTime.now());
      await _saveEpgs();
    }
    await _writeEpgCache(
        id, parsed.programs, parsed.channelNames, parsed.channelIcons);
    return _cachedEpg;
  }

  // ============== EPG 缓存编解码 ==============

  void _applyCachedEpg(String cacheStr) {
    final bytes = base64Decode(cacheStr);
    final map = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final p = (map['p'] as Map?)?.cast<String, List<dynamic>>() ?? {};
    final n = (map['n'] as Map?)?.cast<String, List<dynamic>>() ?? {};
    final i = (map['i'] as Map?)?.cast<String, String>() ?? {};
    _cachedEpg = <String, List<EpgProgram>>{};
    for (final entry in p.entries) {
      final list = <EpgProgram>[];
      for (final raw in entry.value) {
        final m = raw as Map<String, dynamic>;
        list.add(EpgProgram(
          id: m['i']?.toString() ?? '',
          channelId: entry.key,
          title: m['t'] as String? ?? '',
          description: m['d'] as String? ?? '',
          startTime: DateTime.fromMillisecondsSinceEpoch(m['s'] as int? ?? 0),
          endTime: DateTime.fromMillisecondsSinceEpoch(m['e'] as int? ?? 0),
        ));
      }
      _cachedEpg[entry.key] = list;
    }
    _cachedEpgChannelNames = <String, List<String>>{};
    for (final entry in n.entries) {
      _cachedEpgChannelNames[entry.key] =
          (entry.value as List).cast<String>();
    }
    _cachedEpgChannelIcons = i;
  }

  Future<void> _writeEpgCache(
    String epgId,
    Map<String, List<EpgProgram>> programs,
    Map<String, List<String>> channelNames,
    Map<String, String> channelIcons,
  ) async {
    final p = <String, List<Map<String, dynamic>>>{};
    for (final entry in programs.entries) {
      p[entry.key] = entry.value
          .map((pr) => {
                't': pr.title,
                'd': pr.description,
                's': pr.startTime.millisecondsSinceEpoch,
                'e': pr.endTime.millisecondsSinceEpoch,
              })
          .toList();
    }
    final enc = utf8.encode(jsonEncode({
      'p': p,
      'n': channelNames,
      'i': channelIcons,
    }));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheKey(epgId), base64Encode(enc));
    await prefs.setInt(
        _cacheTimeKey(epgId), DateTime.now().millisecondsSinceEpoch);
  }

  /// 手动清除指定 EPG 的缓存（换源或调试用）
  Future<void> clearEpgCache(String epgId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cacheKey(epgId));
    await prefs.remove(_cacheTimeKey(epgId));
  }

  /// 根据频道获取 EPG 节目列表
  List<EpgProgram> getProgramsForChannel(Channel channel) {
    return XmltvEpgParser.findProgramsForChannel(
        channel, _cachedEpg, _cachedEpgChannelNames);
  }

  /// 获取频道台标：优先 M3U tvg-logo，其次 EPG icon
  String getLogoForChannel(Channel channel) {
    if (channel.logoUrl.isNotEmpty) return channel.logoUrl;
    final id = XmltvEpgParser.matchChannelId(
        channel, _cachedEpg, _cachedEpgChannelNames);
    return id == null ? '' : (_cachedEpgChannelIcons[id] ?? '');
  }
}
