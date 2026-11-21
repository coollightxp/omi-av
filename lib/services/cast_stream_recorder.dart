// 条件导出：Web 端空实现，桌面端为投屏流级录制（直接下载媒体字节）
export 'cast_stream_recorder_stub.dart'
    if (dart.library.io) 'cast_stream_recorder_io.dart';
