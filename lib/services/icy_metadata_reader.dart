/// ICY 元数据（电台「正在播放」歌名）读取器。
///
/// MDK/fvp 只给音频数据，不暴露 Icecast/SHOUTcast 的 `StreamTitle`；
/// libmpv 会把它映射成 `media-title`。为了让电台也走 MDK，这里自己开一条
/// 轻量 HTTP 连接（`Icy-MetaData: 1`），按 `icy-metaint` 周期解析
/// `StreamTitle='...'`，把标题交给上层。非 IO 平台（Web）为空实现。
export 'icy_metadata_reader_stub.dart'
    if (dart.library.io) 'icy_metadata_reader_io.dart';
