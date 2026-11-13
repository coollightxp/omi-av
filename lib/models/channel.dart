/// 频道分类 - 用于左侧两级抽屉的第一级
class ChannelCategory {
  final String id;
  final String name;
  final String iconUrl;
  final List<Channel> channels;

  const ChannelCategory({
    required this.id,
    required this.name,
    this.iconUrl = '',
    this.channels = const [],
  });

  ChannelCategory copyWith({
    String? id,
    String? name,
    String? iconUrl,
    List<Channel>? channels,
  }) {
    return ChannelCategory(
      id: id ?? this.id,
      name: name ?? this.name,
      iconUrl: iconUrl ?? this.iconUrl,
      channels: channels ?? this.channels,
    );
  }
}

/// 频道类型：电视（默认）/ 电台
///
/// 电台不是独立入口：与电视共用同一份源与列表，解析时按属性/地址后缀/
/// 分组名自动识别，列表里带类型徽标。
enum ChannelType { tv, radio }

/// 直播频道
class Channel {
  final String id;
  final String name;
  final String logoUrl;
  /// 所有播放源地址（同名频道合并后可能有多个）
  final List<String> streamUrls;
  final String categoryId;
  final bool isFavorite;
  /// EPG 频道标识（用于匹配 XMLTV 节目单）
  final String tvgId;
  /// 节目单中的频道名称（tvg-name）
  final String tvgName;
  /// 分组标题（group-title）
  final String groupTitle;
  /// 播放该频道流时要求的 HTTP User-Agent（M3U 的 http-user-agent 属性，
  /// 例如 APTV 源必须带 AptvPlayer-UA，否则服务器返回 404）
  final String userAgent;

  /// 播放该频道流时要求的 HTTP Referer（网页嗅探出的真实流通常
  /// 校验 Referer/Origin 防盗链）
  final String httpReferer;

  /// 电视 / 电台。电台走音频模式：不显示视频区，播放页换成
  /// Now Playing 卡片（台标 + 台名 + 正在播曲目）
  final ChannelType channelType;

  /// 是否电台
  bool get isRadio => channelType == ChannelType.radio;

  /// 默认播放源（第一个）
  String get streamUrl => streamUrls.first;

  /// 是否为网页频道（TVBox 等源里的 webview:// 链接，
  /// 如 webview://https://www.yangshipin.cn/...）。
  /// 未显式标注时按地址形态保守判断：仅「标准 http(s) 端口 + 站点根路径
  /// 或 .html/.htm/.shtml 页面」才认定为网页；带端口号、带媒体后缀
  /// （m3u8/flv/ts/mp4 等）、带脚本后缀（php/asp 等）或更深无后缀路径的
  /// 一律按视频流交给内置播放器——直播流误判成网页会直接黑屏，
  /// 网页漏判成流则可用底部面板「网页播放器播放」手动切换，代价更小
  bool get isWebPage {
    if (streamUrls.isEmpty) return false;
    final u = streamUrls.first.trim();
    // 显式 webview:// 永远按网页打开（用户自己标注的意图优先）
    if (u.toLowerCase().startsWith('webview://')) return true;
    // 电台一律不进 WebView。音频台的地址五花八门，不少 CDN/电台门户
    // 就是「https://host/」这种根路径——按下面那条规则会被判成网页，
    // 结果打开一个 WebView2 白底页盖在电台画面上：底部面板唤不出、
    // 双击全屏失效、鼠标在框里光标不隐藏（用户反馈的「切电台冒白框」）。
    // 电台就是音频流，没有需要网页承载的场景
    if (isRadio) return false;
    final m = RegExp(r'^(https?)://([^/?#]+)([^?#]*)', caseSensitive: false)
        .firstMatch(u);
    if (m == null) return false;
    final authority = m.group(2)!.toLowerCase();
    final path = m.group(3)!.toLowerCase();
    // 显式非标准端口：基本是流媒体服务（IPTV 常见 :8080/:8090 等）
    final colon = authority.lastIndexOf(':');
    if (colon >= 0) {
      final port = int.tryParse(authority.substring(colon + 1)) ?? -1;
      if (port != 80 && port != 443) return false;
    }
    // 站点根路径（http://host 或 http://host/）：按网页打开
    if (path.isEmpty || path == '/') return true;
    // 明确网页后缀：按网页打开；其它任何后缀都按视频流处理
    final seg = path.substring(path.lastIndexOf('/') + 1);
    final dot = seg.lastIndexOf('.');
    if (dot >= 0) {
      const webExt = {'html', 'htm', 'shtml', 'xhtml'};
      return webExt.contains(seg.substring(dot + 1));
    }
    return false;
  }

  /// 网页频道要打开的真实网址（剥掉 webview:// 前缀；
  /// 自动判定的网页地址无前缀，原样使用）
  String get webPageUrl {
    var inner = streamUrls.first.trim();
    if (inner.toLowerCase().startsWith('webview://')) {
      inner = inner.substring('webview://'.length);
    }
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://').hasMatch(inner)) {
      inner = 'https://$inner';
    }
    return inner;
  }

  const Channel({
    required this.id,
    required this.name,
    this.logoUrl = '',
    required this.streamUrls,
    required this.categoryId,
    this.isFavorite = false,
    this.tvgId = '',
    this.tvgName = '',
    this.groupTitle = '',
    this.userAgent = '',
    this.httpReferer = '',
    this.channelType = ChannelType.tv,
  });

  Channel copyWith({
    String? id,
    String? name,
    String? logoUrl,
    List<String>? streamUrls,
    String? categoryId,
    bool? isFavorite,
    String? tvgId,
    String? tvgName,
    String? groupTitle,
    String? userAgent,
    String? httpReferer,
    ChannelType? channelType,
  }) {
    return Channel(
      id: id ?? this.id,
      name: name ?? this.name,
      logoUrl: logoUrl ?? this.logoUrl,
      streamUrls: streamUrls ?? this.streamUrls,
      categoryId: categoryId ?? this.categoryId,
      isFavorite: isFavorite ?? this.isFavorite,
      tvgId: tvgId ?? this.tvgId,
      tvgName: tvgName ?? this.tvgName,
      groupTitle: groupTitle ?? this.groupTitle,
      userAgent: userAgent ?? this.userAgent,
      httpReferer: httpReferer ?? this.httpReferer,
      channelType: channelType ?? this.channelType,
    );
  }
}
