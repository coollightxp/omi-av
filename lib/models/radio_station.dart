/// 在线电台目录里的一条记录（Radio Browser 的瘦身版）。
///
/// 只留播放与展示需要的字段：地址用 `url_resolved`（服务端已经
/// 跟随过重定向），码率/编码用于在列表里给出「能不能播」的预期。
class RadioStation {
  const RadioStation({
    required this.id,
    required this.name,
    required this.url,
    this.favicon = '',
    this.tags = '',
    this.country = '',
    this.codec = '',
    this.bitrate = 0,
    this.clickCount = 0,
  });

  /// stationuuid，去重与「已添加」判断都靠它
  final String id;
  final String name;
  final String url;
  final String favicon;
  final String tags;
  final String country;
  final String codec;
  final int bitrate;
  final int clickCount;

  /// 列表副标题：国家 · 码率 · 编码（缺什么省什么）
  String get subtitle {
    final parts = <String>[
      if (country.isNotEmpty) country,
      if (bitrate > 0) '${bitrate}kbps',
      if (codec.isNotEmpty) codec.toUpperCase(),
    ];
    return parts.join(' · ');
  }

  /// 标签取前三个，去掉空白项
  String get tagLine {
    final list = tags
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .take(3)
        .toList();
    return list.join(' / ');
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'favicon': favicon,
        'tags': tags,
        'country': country,
        'codec': codec,
        'bitrate': bitrate,
        'clickCount': clickCount,
      };

  factory RadioStation.fromJson(Map<String, dynamic> json) => RadioStation(
        id: (json['id'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        url: (json['url'] ?? '').toString(),
        favicon: (json['favicon'] ?? '').toString(),
        tags: (json['tags'] ?? '').toString(),
        country: (json['country'] ?? '').toString(),
        codec: (json['codec'] ?? '').toString(),
        bitrate: (json['bitrate'] as num?)?.toInt() ?? 0,
        clickCount: (json['clickCount'] as num?)?.toInt() ?? 0,
      );
}
