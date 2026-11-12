import 'dart:convert';

/// 播放列表来源类型
enum PlaylistSourceType {
  url,    // 网络地址
  local,  // 本地文件
  builtin, // 出厂内置（随安装包发布，从 asset 读取，可停用可删除）
  radioLibrary, // 「我的电台」：在线目录搜到后加进来的台，存在本地
}

/// 播放列表文件格式
enum PlaylistFormat {
  m3u,
  txt,
  unknown,
}

/// 播放列表源 - 用户添加的频道列表来源
class PlaylistSource {
  final String id;
  final String name;           // 用户自定义名称
  final String url;            // URL 或本地文件路径
  final PlaylistSourceType type;
  final PlaylistFormat format;
  final DateTime addedAt;
  final DateTime? lastUpdated;

  const PlaylistSource({
    required this.id,
    required this.name,
    required this.url,
    required this.type,
    required this.format,
    required this.addedAt,
    this.lastUpdated,
  });

  /// 内置电台精选：id 固定，便于升级时识别、恢复、去重
  static const String builtinRadioId = 'omi-builtin-radio';
  static const String builtinRadioAsset = 'assets/radio/omi_radio.m3u';

  /// 「我的电台」：内容来自 RadioLibrary（prefs），不落文件
  static const String radioLibraryId = 'omi-radio-library';

  bool get isBuiltin => type == PlaylistSourceType.builtin;

  /// 内置源无法编辑地址（地址是安装包内资源）
  PlaylistSource builtinRadio() => PlaylistSource(
        id: builtinRadioId,
        name: '内置电台精选',
        url: builtinRadioAsset,
        type: PlaylistSourceType.builtin,
        format: PlaylistFormat.m3u,
        addedAt: DateTime.now(),
      );

  PlaylistSource copyWith({
    String? id,
    String? name,
    String? url,
    PlaylistSourceType? type,
    PlaylistFormat? format,
    DateTime? addedAt,
    DateTime? lastUpdated,
  }) {
    return PlaylistSource(
      id: id ?? this.id,
      name: name ?? this.name,
      url: url ?? this.url,
      type: type ?? this.type,
      format: format ?? this.format,
      addedAt: addedAt ?? this.addedAt,
      lastUpdated: lastUpdated ?? this.lastUpdated,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'type': type.name,
        'format': format.name,
        'addedAt': addedAt.toIso8601String(),
        'lastUpdated': lastUpdated?.toIso8601String(),
      };

  factory PlaylistSource.fromJson(Map<String, dynamic> json) {
    return PlaylistSource(
      id: json['id'] as String,
      name: json['name'] as String,
      url: json['url'] as String,
      type: PlaylistSourceType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => PlaylistSourceType.url,
      ),
      format: PlaylistFormat.values.firstWhere(
        (e) => e.name == json['format'],
        orElse: () => PlaylistFormat.unknown,
      ),
      addedAt: DateTime.parse(json['addedAt'] as String),
      lastUpdated: json['lastUpdated'] != null
          ? DateTime.parse(json['lastUpdated'] as String)
          : null,
    );
  }

  static String encodeList(List<PlaylistSource> list) =>
      jsonEncode(list.map((e) => e.toJson()).toList());

  static List<PlaylistSource> decodeList(String str) {
    final List<dynamic> decoded = jsonDecode(str) as List<dynamic>;
    return decoded
        .map((e) => PlaylistSource.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
