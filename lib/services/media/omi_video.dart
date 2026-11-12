/// 统一播放内核门面：上层只 import 这个文件。
///
/// - io（Android / Windows / Linux）：media_kit + libmpv 实现
/// - web：video_player 实现（HTML video 元素）
///
/// 两端暴露完全相同的 API，避免条件编译逻辑渗进业务代码。
export 'omi_video_value.dart';
export 'omi_video_stub.dart'
    if (dart.library.io) 'omi_video_io.dart'
    if (dart.library.js_interop) 'omi_video_web.dart';
