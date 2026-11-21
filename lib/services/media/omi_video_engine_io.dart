import 'omi_video_backend.dart';
import 'omi_video_io.dart';
import 'omi_video_mdk.dart';

/// 内核工厂（io 平台）。
/// 视频节目（含投屏）统一用 MDK；MPV 只留给电台——电台的 ICY 曲目名
/// 与安卓后台原地换台依赖 libmpv。调用方通过 [useMdk] 指定。
OmiVideoBackend createOmiVideoBackend({
  required Uri url,
  Map<String, String>? headers,
  String? formatHint,
  int bufferSeconds = 5,
  bool useMdk = false,
}) {
  if (useMdk) {
    return OmiVideoMdkController.network(
      url,
      headers: headers,
      formatHint: formatHint,
      bufferSeconds: bufferSeconds,
    );
  }
  return OmiVideoController.network(
    url,
    headers: headers,
    formatHint: formatHint,
    bufferSeconds: bufferSeconds,
  );
}
