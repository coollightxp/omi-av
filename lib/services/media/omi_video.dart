/// 统一播放内核门面：上层按需 import。
///
/// - io（Android / Windows / Linux / macOS）：MDK（fvp + video_player）
/// - web：video_player 实现（HTML video 元素）
export 'omi_video_value.dart';
export 'omi_video_stub.dart'
    if (dart.library.io) 'omi_video_mdk.dart'
    if (dart.library.js_interop) 'omi_video_web.dart';
