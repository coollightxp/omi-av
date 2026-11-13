import 'omi_video_backend.dart';
import 'omi_video_web.dart';

/// 内核工厂（Web）：浏览器只有 HTML video 一条路，MDK 不参与。
OmiVideoBackend createOmiVideoBackend({
  required Uri url,
  Map<String, String>? headers,
  String? formatHint,
  int bufferSeconds = 5,
  bool radioSpectrum = false,
  bool audioMeter = false,
  bool useMdk = false,
}) {
  return OmiVideoController.network(
    url,
    headers: headers,
    formatHint: formatHint,
    bufferSeconds: bufferSeconds,
    radioSpectrum: radioSpectrum,
    audioMeter: audioMeter,
  );
}
