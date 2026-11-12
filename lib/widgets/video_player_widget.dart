import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/channel.dart';
import '../services/channel_logo.dart';
import '../services/player_controller.dart';

/// 视频播放器显示组件
class VideoPlayerWidget extends StatelessWidget {
  const VideoPlayerWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerController>(
      builder: (context, controller, _) {
        final vc = controller.videoController;

        // 加载状态
        if (controller.state == PlayerState.loading) {
          return Container(
            color: Colors.black,
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Colors.blueAccent),
                  SizedBox(height: 16),
                  Text(
                    '正在加载直播...',
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ],
              ),
            ),
          );
        }

        // 错误状态
        if (controller.state == PlayerState.error) {
          // 自动重试中/次数用尽的具体提示（"3 秒后自动重试 (1/3)"、
          // "链接失效：…"）；无提示时只显示通用标题
          final detail = controller.lastError;
          return Container(
            color: Colors.black,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline,
                      color: Colors.redAccent, size: 48),
                  const SizedBox(height: 12),
                  const Text(
                    '播放失败',
                    style: TextStyle(color: Colors.white, fontSize: 16),
                  ),
                  if (detail != null && detail.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        detail,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 13),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    onPressed: () {
                      final ch = controller.currentChannel;
                      if (ch != null) {
                        controller.playChannel(ch);
                      } else if (controller.flatChannels.isNotEmpty) {
                        // 启动恢复失败等场景下 currentChannel 可能为空：
                        // 兜底播放列表第一个频道，避免按钮完全无反应
                        controller
                            .playChannel(controller.flatChannels.first);
                      }
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试'),
                  ),
                ],
              ),
            ),
          );
        }

        // 空闲状态
        if (vc == null || !vc.value.isInitialized) {
          return Container(
            color: Colors.black,
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.live_tv, color: Colors.white30, size: 64),
                  SizedBox(height: 16),
                  Text(
                    '请选择频道开始观看',
                    style: TextStyle(color: Colors.white54, fontSize: 14),
                  ),
                ],
              ),
            ),
          );
        }

        // 电台：流里没有画面，用 Now Playing 卡片替代视频纹理。
        // 视频纹理仍在后台解码（走音频轨），只是不显示。
        final radioCh = controller.currentChannel;
        if (radioCh != null && radioCh.isRadio) {
          return _RadioStage(controller: controller, channel: radioCh);
        }

        // 视频播放
        // 部分投屏流（抖音等 MP4/FLV）音频先就绪、视频尺寸上报为 0，
        // 直接用 size 会把纹理缩成 0×0 → 有声无画面；
        // 此时用 16:9 兜底，等视频帧到达、size 更新后自动恢复真实比例
        final w = vc.value.size.width;
        final h = vc.value.size.height;
        final hasSize = w > 0 && h > 0;
        // 旋转：用独立的 ValueNotifier 只重建视频层，避免整 Stack 灰屏
        return ValueListenableBuilder<int>(
          valueListenable: controller.videoRotation,
          builder: (context, rot, _) {
            return SizedBox.expand(
              child: FittedBox(
                fit: BoxFit.contain,
                child: RotatedBox(
                  quarterTurns: rot,
                  child: SizedBox(
                    width: hasSize ? w : 16,
                    height: hasSize ? h : 9,
                    // 门面 build()：io 走 media_kit 的 Video，web 走 VideoPlayer
                    child: vc.build(),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// 电台音频模式（Now Playing）。
///
/// 电台没有画面，黑屏会让人以为"没播"：这里用台标 + 台名 +
/// 正在收听状态替代视频区，播放/暂停/切台都照旧走底部面板与遥控器。
/// 后续（方案 12.3）再加 FFT 波形与实时字幕。
class _RadioStage extends StatelessWidget {
  const _RadioStage({required this.controller, required this.channel});

  final PlayerController controller;
  final Channel channel;

  @override
  Widget build(BuildContext context) {
    final ch = channel;
    final name = ch.name;
    // 有 EPG/ICY 曲目就显示当前节目，没有就只显示收听状态
    final now = controller.currentProgram?.title ??
        controller.getNowPlayingInfo().programTitle;

    return Container(
      // 与启动页同一套暖黑底，避免纯黑发灰
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.2),
          radius: 1.2,
          colors: [Color(0xFF1A1209), Color(0xFF000000)],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _logo(ch),
            const SizedBox(height: 22),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 26,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _LiveDot(playing: controller.isPlaying),
                const SizedBox(width: 8),
                Text(
                  controller.isPlaying ? '正在收听' : '已暂停',
                  style: const TextStyle(
                    color: Color(0xCCFFFFFF),
                    fontSize: 14,
                  ),
                ),
              ],
            ),
            if (now.isNotEmpty && now != name) ...[
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  now,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0x99FFFFFF),
                    fontSize: 15,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 台标：本地 asset 优先 → 在线 logo → 首字兜底（列表永不空白）
  Widget _logo(Channel ch) {
    const size = 176.0;
    Widget fallback() => Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0x14FFFFFF),
          ),
          child: Text(
            ch.name.isEmpty ? '📻' : ch.name.characters.first,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 64,
              fontWeight: FontWeight.w600,
            ),
          ),
        );

    Widget circle(Widget child) => Container(
          width: size,
          height: size,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.06),
            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
          ),
          child: child,
        );

    final asset = ChannelLogo.assetFor(ch);
    if (asset.isNotEmpty) {
      return circle(Image.asset(
        asset,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => fallback(),
      ));
    }
    if (ch.logoUrl.isNotEmpty) {
      return circle(Image.network(
        ch.logoUrl,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => fallback(),
      ));
    }
    return fallback();
  }
}

/// 播放中跳动的三点（暂停时静止），成本极低但画面不至于是死的
class _LiveDot extends StatefulWidget {
  const _LiveDot({required this.playing});

  final bool playing;

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void initState() {
    super.initState();
    if (widget.playing) _c.repeat();
  }

  @override
  void didUpdateWidget(covariant _LiveDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing && !_c.isAnimating) {
      _c.repeat();
    } else if (!widget.playing && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        // 呼吸式明暗，不跳动（电台画面本来就静，跳点太吵）
        final t = _c.isAnimating ? 0.45 + 0.55 * (0.5 + 0.5 *
            math.sin(_c.value * 2 * math.pi)) : 0.7;
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFFFF7A45).withValues(alpha: t),
          ),
        );
      },
    );
  }
}
