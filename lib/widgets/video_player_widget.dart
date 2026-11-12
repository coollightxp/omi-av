import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/channel.dart';
import '../core/widgets/channel_badge.dart';
import '../core/theme/app_colors.dart';
import '../core/widgets/audio_wave.dart';
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
                        controller.playChannel(controller.flatChannels.first);
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
/// 电台没有画面，黑屏会让人以为"没播"：这里用台标 + 波形 + 台名 +
/// 正在收听状态替代视频区，播放/暂停/切台都照旧走底部面板与遥控器。
/// 波形见 [AudioWave]（不是真 FFT，播放器不暴露 PCM，靠播放态驱动起伏）。
class _RadioStage extends StatelessWidget {
  const _RadioStage({required this.controller, required this.channel});

  final PlayerController controller;
  final Channel channel;

  @override
  Widget build(BuildContext context) {
    final ch = channel;
    final name = ch.name;

    return Container(
      // 与启动页同一套暖黑底，避免纯黑发灰
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.2),
          radius: 1.2,
          colors: [Color(0xFF1A1209), Color(0xFF000000)],
        ),
      ),
      // 小窗/分屏时整体等比缩放，不裁不溢
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _logo(ch),
                const SizedBox(height: 20),
                // 声音的可视化：优先用 mpv showwaves 输出的真实波形纹理，
                // 拿不到帧（滤镜不可用/流不支持）就退回缓动波形
                _wave(),
                const SizedBox(height: 14),
                Text(
                  name,
                  maxLines: 1,
                  textAlign: TextAlign.center,
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
                  mainAxisAlignment: MainAxisAlignment.center,
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
                    // 音频流标识：一眼看出这是"只有声音"的台，不是画面没出
                    const SizedBox(width: 10),
                    _AudioTag(playing: controller.isPlaying),
                  ],
                ),
                // 正在播的曲目/节目：优先 ICY 实时元数据（歌名会在
                // 副歌换歌时自己变），其次 EPG 节目名。单独订阅播放器值，
                // 避免整屏跟着 position 每 100ms 重建
                AnimatedBuilder(
                  animation: Listenable.merge([controller.videoController]),
                  builder: (context, _) {
                    final now = _nowText();
                    if (now.isEmpty || now == name) {
                      return const SizedBox(height: 6);
                    }
                    return Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // ICY 曲目是"歌名 - 歌手"的即时状态，给个微型现场标
                          if (_isIcy) ...[
                            const _IcyNowLabel(),
                            const SizedBox(height: 4),
                          ],
                          Text(
                            now,
                            maxLines: 2,
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xCCFFFFFF),
                              fontSize: 15,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 6),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 波形区：真实频谱纹理 → 缓动波形 两级回退
  Widget _wave() {
    final vc = controller.videoController;
    if (vc == null) return _fallbackWave();
    return AnimatedBuilder(
      animation: vc,
      builder: (context, _) {
        // mpv 的 showwaves 一旦出帧，宽高就非 0
        if (vc.value.size.width <= 0) return _fallbackWave();
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: 320,
            height: 58,
            color: const Color(0xFF0B0805),
            child: vc.build(fit: BoxFit.cover),
          ),
        );
      },
    );
  }

  Widget _fallbackWave() => AudioWave(
        active: controller.isPlaying,
        height: 44,
        bars: 25,
        barWidth: 3.0,
        gap: 5.0,
      );

  bool get _isIcy =>
      (controller.videoController?.value.mediaTitle ?? '').isNotEmpty;

  /// 当前曲目/节目的取值顺序：ICY 实时曲目 → EPG 当前节目 → 空
  String _nowText() {
    final icy =
        (controller.videoController?.value.mediaTitle ?? '').trim();
    if (icy.isNotEmpty) return icy;
    return controller.currentProgram?.title ??
        controller.getNowPlayingInfo().programTitle;
  }

  /// 台标：内置库 → 源内 tvg-logo → Radio Browser → 字母台标
  /// （四级回退统一由 ChannelBadge 处理，与频道列表完全一致）
  Widget _logo(Channel ch) {
    const size = 176.0;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: ChannelBadge(
        channel: ch,
        size: size - 4,
        circular: true,
        background: Colors.white.withValues(alpha: 0.06),
      ),
    );
  }
}

/// 「正在播」小标：给 ICY 曲目用，红点 + 字样，和"这是台名"区分开
class _IcyNowLabel extends StatelessWidget {
  const _IcyNowLabel();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 5,
          height: 5,
          decoration: const BoxDecoration(
            color: AppColors.live,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          '正在播',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.50),
            fontSize: 11,
            letterSpacing: 1.5,
          ),
        ),
      ],
    );
  }
}

/// 「音频流」小标：耳机图标 + 三根跳动条。
/// 和底部面板的「音频直播」徽章是同一个语义，两处都出现
/// 是刻意的——用户可能只看大屏，也可能只看面板。
class _AudioTag extends StatelessWidget {
  const _AudioTag({required this.playing});

  final bool playing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.wave.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.wave.withValues(alpha: 0.30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.headphones, size: 12, color: AppColors.wave),
          const SizedBox(width: 5),
          Text(
            '音频流',
            style: TextStyle(
              color: AppColors.wave.withValues(alpha: 0.95),
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(width: 6),
          AudioBars(
              active: playing, height: 10, bars: 3, barWidth: 2.2, gap: 2.0),
        ],
      ),
    );
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
        final t = _c.isAnimating
            ? 0.45 + 0.55 * (0.5 + 0.5 * math.sin(_c.value * 2 * math.pi))
            : 0.7;
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
