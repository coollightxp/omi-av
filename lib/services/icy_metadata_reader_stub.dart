/// Web：没有 dart:io，媒体元素自己解码，不读 ICY。
class IcyMetadataReader {
  IcyMetadataReader({required this.onTitle});

  final void Function(String title) onTitle;

  Future<void> start(Uri url, {Map<String, String>? headers}) async {}

  Future<void> stop() async {}
}
