import 'omi_video_backend.dart';
import 'omi_video_mdk.dart';

/// 内核工厂（io 平台）：统一 MDK（fvp + video_player）。
///
/// 视频、投屏、电台全部走这一条内核，不再有 MPV 分支：
/// - MDK 在老显卡/老系统与安卓上的兼容性更好；
/// - 截图（fvp snapshot）与录制（fvp record）在两个平台都可用；
/// - 电台的 ICY 曲目名由 `IcyMetadataReader` 单独补齐。
OmiVideoBackend createOmiVideoBackend({
  required Uri url,
  Map<String, String>? headers,
  String? formatHint,
  int bufferSeconds = 5,
}) {
  return OmiVideoMdkController.network(
    url,
    headers: headers,
    formatHint: formatHint,
    bufferSeconds: bufferSeconds,
  );
}
