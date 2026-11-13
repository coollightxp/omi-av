import 'omi_video_backend.dart';
import 'omi_video_io.dart';
import 'omi_video_mdk.dart';

/// 内核工厂（io 平台）：按用户设置选择 mpv 或 MDK。
OmiVideoBackend createOmiVideoBackend({
  required Uri url,
  Map<String, String>? headers,
  String? formatHint,
  int bufferSeconds = 5,
  bool radioSpectrum = false,
  bool audioMeter = false,
  bool useMdk = false,
}) {
  if (useMdk) {
    return OmiVideoMdkController.network(
      url,
      headers: headers,
      formatHint: formatHint,
      bufferSeconds: bufferSeconds,
      radioSpectrum: radioSpectrum,
      audioMeter: audioMeter,
    );
  }
  return OmiVideoController.network(
    url,
    headers: headers,
    formatHint: formatHint,
    bufferSeconds: bufferSeconds,
    radioSpectrum: radioSpectrum,
    audioMeter: audioMeter,
  );
}
