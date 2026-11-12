import 'dart:ui' show Size;

/// 播放器状态快照（与具体内核无关）。
///
/// Web 端由 video_player 提供，桌面/移动端由 media_kit(libmpv) 提供，
/// 上层只依赖这个值对象，不感知内核差异。
class OmiVideoValue {
  const OmiVideoValue({
    this.isInitialized = false,
    this.isPlaying = false,
    this.isBuffering = false,
    this.hasError = false,
    this.isCompleted = false,
    this.size = Size.zero,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.bufferedEnd = Duration.zero,
    this.errorDescription,
  });

  final bool isInitialized;
  final bool isPlaying;
  final bool isBuffering;
  final bool hasError;
  final bool isCompleted;
  final Size size;
  final Duration position;
  final Duration duration;

  /// 已缓冲到的位置（部分平台不上报，恒为 0 时上层退化为固定超时判定）
  final Duration bufferedEnd;
  final String? errorDescription;

  double get aspectRatio =>
      size.height <= 0 ? 16 / 9 : size.width / size.height;

  OmiVideoValue copyWith({
    bool? isInitialized,
    bool? isPlaying,
    bool? isBuffering,
    bool? hasError,
    bool? isCompleted,
    Size? size,
    Duration? position,
    Duration? duration,
    Duration? bufferedEnd,
    String? errorDescription,
  }) {
    return OmiVideoValue(
      isInitialized: isInitialized ?? this.isInitialized,
      isPlaying: isPlaying ?? this.isPlaying,
      isBuffering: isBuffering ?? this.isBuffering,
      hasError: hasError ?? this.hasError,
      isCompleted: isCompleted ?? this.isCompleted,
      size: size ?? this.size,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      bufferedEnd: bufferedEnd ?? this.bufferedEnd,
      errorDescription: errorDescription ?? this.errorDescription,
    );
  }
}
