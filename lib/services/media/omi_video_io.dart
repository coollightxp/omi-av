import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../web_diag.dart';
import 'omi_video_backend.dart';
import 'omi_video_value.dart';

/// media_kit(libmpv) 内核实现：Android / Windows / Linux。
///
/// 设计要点：
/// - 与旧 video_player/fvp 栈保持同构 API，业务层零改动迁移；
/// - libmpv 自带 HLS/DASH/RTSP 与断点续传，不再需要 fvp 注册与 MDK SDK；
/// - 事件全部转成 [OmiVideoValue]，上层只依赖值对象。
class OmiVideoController extends ChangeNotifier implements OmiVideoBackend {
  OmiVideoController.network(
    Uri url, {
    Map<String, String>? headers,
    String? formatHint,
    int bufferSeconds = 5,
  })  : _url = url,
        _headers = headers {
    MediaKit.ensureInitialized();
    final bytes = (bufferSeconds.clamp(3, 120)) * 1024 * 1024;
    _player = Player(
      configuration: PlayerConfiguration(
        title: 'Omi',
        bufferSize: bytes,
        logLevel: MPVLogLevel.error,
      ),
    );
    _video = VideoController(_player);
    _bindStreams();
    _observeMediaTitle();
  }

  /// 当前流地址/HTTP 头：原地换源（[openInPlace]）会就地改写
  Uri _url;
  Map<String, String>? _headers;
  late final Player _player;
  late final VideoController _video;
  final List<StreamSubscription<dynamic>> _subs = [];

  OmiVideoValue _value = const OmiVideoValue();
  bool _disposed = false;


  @override
  OmiVideoValue get value => _value;

  void _set(OmiVideoValue next) {
    if (_disposed) return;
    _value = next;
    notifyListeners();
  }

  /// 电台流的曲目元数据：libmpv 把 ICY `StreamTitle` 映射到 `media-title`，
  /// 属性变化事件比轮询省事也更及时。Web 端没有 mpv，不参与。
  ///
  /// 部分电台（实测 AsiaFM 系列）的 Icecast 转码端有毛病：UTF-8 文本每
  /// 三个字节序列的尾字节被替换成 `?`（「叶蒨文 - 曾经心痛」发出来就成
  /// 了缺尾字节的残流），libmpv 对有效序列正常解码、对残字节按 latin1
  /// 吐出 `æ`/`å` 一类残渣。字节在服务器端已经丢了，客户端无法还原，
  /// 这里只做显示清理：删掉替换符、控制符与夹在中文/标点旁的残渣字符
  /// 和孤立 `?`，让「正在播放」至少可读。
  void _observeMediaTitle() {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    unawaited(() async {
      try {
        await platform.observeProperty('media-title', (value) async {
          final t = sanitizeIcyTitle(value.trim());
          if (t.isEmpty || t == _value.mediaTitle) return;
          _set(_value.copyWith(mediaTitle: t));
        });
      } catch (e) {
        // 某些内核/资源不允许观测：静默降级，标题回落到台名
        debugPrint('[OmiVideo] observe media-title failed: $e');
      }
    }());
  }

  /// 清理 ICY 曲目元数据里的转码残渣（见 [_observeMediaTitle] 注释）。
  /// 只在文本里确实有中文时才动 `?` 和 latin1 残渣，纯英文歌名原样放行。
  static String sanitizeIcyTitle(String raw) {
    var s = raw.replaceAll('\uFFFD', '');
    // C1 控制区残渣（latin1 视角下的不可打印字节）
    s = s.replaceAll(RegExp('[\u0080-\u009F]'), '');
    if (!s.contains(RegExp('[\u4e00-\u9fff]'))) return s;
    // latin1 扩展残渣：紧邻中文/全角标点的 æ å ç 一类字符
    const ctx = '[\u4e00-\u9fff\u3000-\u303F\uFF00-\uFFEF（）()\\[\\]·，。：]';
    s = s.replaceAll(RegExp('(?<=$ctx)'), '');
    s = s.replaceAll(RegExp('(?=$ctx)'), '');
    // 服务器替换尾字节产生的孤立 ?（夹在中文/标点之间或行尾）
    s = s.replaceAll(RegExp('\\?(?=$ctx|[-—–\\s]|\$)'), '');
    // 残渣清掉后可能留下 "中文 -  (x)" 之类的空洞，压掉多余空格
    s = s.replaceAll(RegExp(' {2,}'), ' ').replaceAll(RegExp(' ([)）])'), ')');
    return s.trim();
  }

  void _bindStreams() {
    _subs.addAll([
      _player.stream.playing.listen(
        (v) => _set(_value.copyWith(isPlaying: v)),
      ),
      _player.stream.buffering.listen(
        (v) => _set(_value.copyWith(isBuffering: v)),
      ),
      _player.stream.completed.listen(
        (v) => _set(_value.copyWith(isCompleted: v)),
      ),
      _player.stream.error.listen(
        (e) => _set(
          _value.copyWith(hasError: true, errorDescription: e.toString()),
        ),
      ),
      _player.stream.width.listen(
        (w) => _set(
          _value.copyWith(
            size: Size(
              (w ?? _value.size.width).toDouble(),
              _value.size.height,
            ),
          ),
        ),
      ),
      _player.stream.height.listen(
        (h) => _set(
          _value.copyWith(
            size: Size(
              _value.size.width,
              (h ?? _value.size.height).toDouble(),
            ),
          ),
        ),
      ),
      _player.stream.position.listen(
        (p) => _set(_value.copyWith(position: p)),
      ),
      _player.stream.duration.listen(
        (d) => _set(_value.copyWith(duration: d)),
      ),
      _player.stream.buffer.listen(
        (b) => _set(_value.copyWith(bufferedEnd: b)),
      ),
    ]);
  }

  Future<void> initialize() async {
    // 必须在 open 之前设：这是 demuxer 的 AVOption，open 时读一次
    await _applyFaultTolerance();
    // 后台起播（安卓通知栏切台）：尽量把视频管线摘掉。
    //
    // 注意 mpv 的 `vid` 是「每文件选项」：open 之前设的会被新文件重置，
    // 所以光靠下面这一次不够（v2.1.26 就是这么做的，用户实测后台切台
    // 仍然停住）。这里再加一刀：open 发起后 200ms 再补设一次，抢在
    // 首帧解码之前把视频轨关掉——后台没有 Surface，只要视频管线还在，
    // open 就会一直卡着不返回，声音自然也不出。
    if (_videoDisabled) {
      try {
        await _player.setVideoTrack(VideoTrack.no());
      } catch (_) {}
    }
    final opening = _player.open(
      Media(_url.toString(), httpHeaders: _headers),
      play: false,
    );
    if (_videoDisabled) {
      Timer(const Duration(milliseconds: 200), () async {
        if (_disposed) return;
        try {
          await _player.setVideoTrack(VideoTrack.no());
        } catch (_) {}
      });
    }
    try {
      // 后台给 open 加个上限：万一视频管线还是没跳过，也不能让整个
      // 起播流程挂死在 await 上（回前台才恢复 = 用户看到的现象）
      await (_videoDisabled
          ? opening.timeout(const Duration(seconds: 6))
          : opening);
    } on TimeoutException {
      debugPrint('[OmiVideo] 后台 open 超时：按已起播继续（音频优先）');
    }
    _playerOpened = true;
    // open 返回即 demuxer 就绪；画面尺寸可能稍后才上报，
    // 这里用当前已知值兜底，后续由 stream 持续修正。
    final w = _player.state.width ?? 0;
    final h = _player.state.height ?? 0;
    _set(
      _value.copyWith(
        isInitialized: true,
        size: Size(w.toDouble(), h.toDouble()),
        duration: _player.state.duration,
      ),
    );
  }

  /// 解封装容错：`err_detect=ignore_err`。
  ///
  /// 部分 Icecast 电台（实测 AsiaFM 亚洲粤语台 `yyt.asiafm.net:8000/asiafm`，
  /// Content-Type: audio/aacp）的 AAC 流里混着结构损坏的包——PCE 采样率索引
  /// 与容器配置不符、保留了保留位、声道元素未分配。ffmpeg 默认把这类包判成
  /// corrupt 后整段解码失败，libmpv 抛 `Error decoding audio`，上层就显示
  /// 「播放失败」。而损坏包是随机出现的，所以表现成「有时候切过去就报错、
  /// 有时候又正常」。
  ///
  /// 让 demuxer 直接丢掉坏包（不送进解码器）即可：实测该台连续解码 8 秒，
  /// astats 电平正常、无 NaN/Inf、听感无感。对正常流没有副作用——它只是把
  /// 「碰到轻微损坏就整段失败」改成「跳过损坏继续播」。
  
  Future<void> _applyFaultTolerance() async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty('demuxer-lavf-o', 'err_detect=ignore_err');
    } catch (e) {
      debugPrint('[OmiVideo] err_detect failed: $e');
    }
  }

  /// 原地换源：不新建 Player/VideoController，只让现有 mpv 换一路流。
  ///
  /// 专治「安卓通知栏切台后不出声」：后台没有 Surface，新建内核的
  /// texture 管线拿不到画布，open 会卡在等纹理；而原地 open 复用已有
  /// 音频输出，后台立刻换台出声。
  @override
  Future<void> openInPlace(Uri url, {Map<String, String>? headers}) async {
    if (_disposed) throw StateError('controller released');
    _url = url;
    _headers = headers;
    _videoDisabled = true;
    await _applyFaultTolerance();
    _setAudioDisplay(false);
    try {
      // 后台没有 Surface：先把视频轨摘掉，open 才不会停在等纹理上
      await _player.setVideoTrack(VideoTrack.no());
    } catch (_) {}
    final opening = _player.open(
      Media(url.toString(), httpHeaders: headers),
      play: false,
    );
    // mpv 的 `vid` 是每文件选项：open 之后会被新文件重置，抢在首帧
    // 解码前再补一刀（与 initialize 里的处理一致）
    Timer(const Duration(milliseconds: 200), () async {
      if (_disposed) return;
      try {
        await _player.setVideoTrack(VideoTrack.no());
      } catch (_) {}
    });
    try {
      await opening.timeout(const Duration(seconds: 6));
    } on TimeoutException {
      debugPrint('[OmiVideo] 后台原地换台 open 超时：按已起播继续');
    }
    _playerOpened = true;
    _set(
      _value.copyWith(
        isInitialized: true,
        hasError: false,
        isCompleted: false,
        mediaTitle: '',
        position: Duration.zero,
        duration: Duration.zero,
        bufferedEnd: Duration.zero,
      ),
    );
  }

  Future<void> play() async {
    await _player.play();
    _set(_value.copyWith(isPlaying: true, hasError: false));
  }

  Future<void> pause() async {
    await _player.pause();
    _set(_value.copyWith(isPlaying: false));
  }

  Future<void> setLooping(bool loop) async {
    await _player.setPlaylistMode(loop ? PlaylistMode.loop : PlaylistMode.none);
  }

  Future<void> seekTo(Duration position) async {
    await _player.seek(position);
  }

  Future<void> setVolume(double volume) async {
    await _player.setVolume((volume.clamp(0.0, 1.0)) * 100);
  }

  Widget build({BoxFit fit = BoxFit.contain}) {
    return Video(
      controller: _video,
      controls: NoVideoControls,
      fit: fit,
    );
  }

  Size get videoSize => _value.size;

  /// 原生截帧：libmpv 直接输出 PNG 字节
  Future<Uint8List?> snapshotPng() async {
    try {
      return await _player.screenshot(format: 'image/png');
    } catch (_) {
      return null;
    }
  }

  /// 录制：libmpv 的 stream-record 直接落盘为容器文件
  Future<bool> startRecord(String path) async {
    try {
      final platform = _player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('stream-record', path);
        return true;
      }
    } catch (_) {}
    return false;
  }

  Future<void> stopRecord() async {
    try {
      final platform = _player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('stream-record', '');
      }
    } catch (_) {}
  }

  /// 应用音频滤镜（声音实验室，方案 12.3 第二档）。
  /// [lavfi] 为 lavfi 滤镜串（不含外层 lavfi=[] 包装）；null/空清除。
  /// 换台会重建控制器，调用方需在新建控制器后重新应用。
  @override
  Future<void> setVideoOutputDisabled(bool disabled) async {
    // 先同步记下标记：可能还没 initialize（后台切台 = 新建实例后立刻
    // 调这个方法），交给 open 前统一生效
    _videoDisabled = disabled;
    _setAudioDisplay(!disabled);
    if (!_playerOpened) return;
    try {
      await _player
          .setVideoTrack(disabled ? VideoTrack.no() : VideoTrack.auto());
    } catch (_) {
      // 轨道切换失败不影响音频播放
    }
  }

  /// mpv 的 `audio-display`：带内嵌封面的音频流（很多电台 MP3 的
  /// ID3 APIC）默认会被 mpv 当成一路视频去建 vo。后台没有 Surface，
  /// 这一路建不起来，open 就卡在那里——表现为「切了台不出声，回界面
  /// 才接着放」。后台一律关掉，回前台再打开。
  void _setAudioDisplay(bool on) {
    final p = _player.platform;
    if (p is! NativePlayer) return;
    try {
      unawaited(p.setProperty('audio-display', on ? 'auto' : 'no'));
    } catch (_) {}
  }

  /// 视频输出是否被关闭（后台起播时 open 前要跳过视频轨）
  bool _videoDisabled = false;

  /// 播放器是否已经 open 过（open 之前的轨道设置要在 initialize 里做）
  bool _playerOpened = false;


  /// 异步释放 native 资源（可 await / 可加超时）。
  /// 不覆盖 ChangeNotifier.dispose（其返回 void），由上层显式调用。
  Future<void> release() async {
    if (_disposed) return;
    _disposed = true;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    try {
      await _player.dispose();
    } catch (_) {}
  }

  @override
  void dispose() {
    // 兜底路径：没人 await 的调用方也要释放 native 资源。
    // release 自身幂等，与上层显式调用不冲突
    unawaited(release());
    super.dispose();
  }
}
