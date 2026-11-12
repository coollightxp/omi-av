import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/epg_program.dart';
import '../core/theme/app_colors.dart';
import '../core/widgets/audio_wave.dart';
import '../core/widgets/channel_badge.dart';
import '../core/theme/app_density.dart';
import '../core/theme/app_typography.dart';
import '../core/widgets/ghost_button.dart';
import '../player/widgets/source_stepper.dart';
import '../services/player_controller.dart';
import 'scaled_panel.dart';

/// 底部信息/控制面板
/// 布局（参考电视播放器）：台标 | 当前节目(大字)+时段/频道/分辨率/线路 | 控制按钮
/// 点播文件时顶部显示可拖动进度条，直播流不显示
///
/// 遥控器导航（TV 盒子无鼠标）：面板可见时，←/→ 在可用按钮间移动高亮，
/// OK 激活当前按钮，返回键由播放页负责关闭面板。
class BottomProgramPanel extends StatefulWidget {
  final bool isVisible;
  final VoidCallback onTogglePlayPause;
  final VoidCallback onScreenshot;
  final VoidCallback onToggleRecord;

  /// 网页/内置播放器来回切换（无可切流时置灰不可点）
  final VoidCallback? onSwitchWebNative;

  /// 重载当前频道（网页卡死/黑屏时手动恢复）
  final VoidCallback? onReload;

  /// 遥控器激活「跳转类」按钮（扫码）后通知播放页关闭面板
  final VoidCallback? onDismissRemote;

  /// 鼠标悬停在面板上/移出面板（悬停期间不自动隐藏）
  final VoidCallback? onHoverEnter;
  final VoidCallback? onHoverExit;
  final VoidCallback? onHoverMove;

  const BottomProgramPanel({
    super.key,
    required this.isVisible,
    required this.onTogglePlayPause,
    required this.onScreenshot,
    required this.onToggleRecord,
    this.onSwitchWebNative,
    this.onReload,
    this.onDismissRemote,
    this.onHoverEnter,
    this.onHoverExit,
    this.onHoverMove,
  });

  @override
  State<BottomProgramPanel> createState() => BottomProgramPanelState();
}

/// 面板内一个可由遥控器激活的按钮
class _KbAction {
  final String id;
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// 激活后是否关闭面板（跳转到其它面板/弹层 = true）
  final bool dismiss;

  const _KbAction(this.id, this.icon, this.tooltip, this.onPressed,
      {this.dismiss = false});
}

class BottomProgramPanelState extends State<BottomProgramPanel> {
  /// 遥控器当前高亮的按钮 id（null = 无高亮）。
  /// 用 id 而非索引：播放状态变化会让按钮顺序/可用性变化（如投屏按钮），
  /// 高亮不会因此错位。
  String? _kbId;

  /// 最近一次构建出的动作列表（与按钮排列顺序一致）
  List<_KbAction> _actions = const [];

  /// 当前可激活（未禁用）的动作
  List<_KbAction> get _enabledActions =>
      _actions.where((a) => a.onPressed != null).toList();

  @override
  void didUpdateWidget(BottomProgramPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 面板每次被呼出时，默认高亮「播放/暂停」（不可用时取第一个可用按钮）
    if (widget.isVisible && !oldWidget.isVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final enabled = _enabledActions;
        if (enabled.isEmpty) {
          setState(() => _kbId = null);
          return;
        }
        final play = enabled.where((a) => a.id == 'playpause');
        setState(() =>
            _kbId = play.isNotEmpty ? play.first.id : enabled.first.id);
      });
    }
  }

  /// 遥控器按键：←/→ 在【可用】按钮间移动高亮，OK 激活当前按钮
  void handleRemoteKey(String action, {required bool isDown}) {
    if (!widget.isVisible) return;
    final enabled = _enabledActions;
    if (enabled.isEmpty) return;
    if (action == 'left' || action == 'right') {
      if (!isDown) return;
      var i = enabled.indexWhere((a) => a.id == _kbId);
      setState(() {
        if (i < 0) {
          i = action == 'right' ? 0 : enabled.length - 1;
        } else if (action == 'right') {
          i = (i + 1) % enabled.length;
        } else {
          i = (i - 1 + enabled.length) % enabled.length;
        }
        _kbId = enabled[i].id;
      });
      return;
    }
    if (action == 'ok' && isDown) {
      final i = enabled.indexWhere((a) => a.id == _kbId);
      final a = i >= 0 ? enabled[i] : enabled.first;
      a.onPressed?.call();
      if (a.dismiss) widget.onDismissRemote?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    // 宽屏（电视/桌面）：面板做成居中悬浮卡片，两侧留白、底边抬升；
    // 窄屏贴近两侧，避免内容被挤
    final screenW = MediaQuery.of(context).size.width;
    // scale 只用于内部尺寸（台标/内边距/字号）分支；面板本身不再
    // 整体缩放——0.72 的等比缩放会让面板视觉宽度只剩 72%，两侧大留白，
    // 按钮行有 FittedBox 自适应压缩，直接按真实宽度铺满即可
    final scale = panelScaleOf(context) < 1.0 ? 0.72 : 1.0;
    // 用户多次反馈手机面板要尽量宽：窄屏完全贴边（0 边距）
    final hPad = screenW > 1200 ? 72.0 : (screenW > 900 ? 40.0 : 0.0);
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      left: hPad,
      right: hPad,
      bottom: widget.isVisible ? (screenW > 900 ? 16 : 8) : -320,
      child: MouseRegion(
        onEnter: (_) => widget.onHoverEnter?.call(),
        onExit: (_) => widget.onHoverExit?.call(),
        onHover: (_) => widget.onHoverMove?.call(),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: widget.isVisible ? 1.0 : 0.0,
          child: ScaledPanel(
            alignment: Alignment.bottomCenter,
            scale: 1.0,
            child: Container(
              decoration: BoxDecoration(
                // 与设置面板 / 左右抽屉同一套表面色：深蓝灰 + 细描边
                color: AppColors.overlay,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.stroke),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.45),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  // 贴近屏幕左右两端（横向拉长），上下略加高保持比例
                  padding: scale < 1
                      ? const EdgeInsets.fromLTRB(6, 16, 4, 14)
                      : const EdgeInsets.fromLTRB(22, 16, 18, 10),
                  child: Consumer<PlayerController>(
                    builder: (context, c, _) => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (c.isSeekable) _buildSeekBar(c),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            _buildLogo(c, scale),
                            SizedBox(width: AppDensity.of(context).logoGap),
                            Expanded(child: _buildInfo(c, scale)),
                            Flexible(
                              flex: 0,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerRight,
                                child: _buildButtons(c),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ==================== 台标 ====================

  Widget _buildLogo(PlayerController c, double scale) {
    final d = AppDensity.of(context);
    final size = d.logoSize;
    final ch = c.currentChannel;
    if (ch == null) {
      // 无频道（网页态/空态）：占位图标
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.white12,
          borderRadius: BorderRadius.circular(scale < 1 ? 10 : 16),
        ),
        child: Icon(Icons.live_tv,
            color: Colors.white54, size: scale < 1 ? 46 : 64),
      );
    }
    // 台标四级回退统一走 ChannelBadge（内置库 → 源 logo →
    // EPG 匹配 logo → Radio Browser → 字母台标）。
    // 面板固定用圆角方形：它和视频信息栏同一行，圆形会显得突兀
    return ChannelBadge(
      channel: ch,
      size: size,
      circular: false,
      background: Colors.white10,
      extraLogoUrls: [c.currentLogo],
    );
  }

  // ==================== 节目信息 ====================

  Widget _buildInfo(PlayerController c, double scale) {
    final t = AppTypography.of(context);
    // 投屏态：信息区换成"正在投屏 · 片名/频道名"，不显示 EPG 节目
    if (c.isCasting) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            c.currentChannel == null
                ? '正在投屏'
                : c.displayTitle(c.currentChannel!),
            style: TextStyle(
              color: Colors.white,
              fontSize: scale < 1 ? t.title - 2 : t.title,
              fontWeight: FontWeight.bold,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          SizedBox(height: scale < 1 ? 3 : 5),
          Row(children: [
            const Icon(Icons.cast_connected,
                size: 14, color: Color(0xFFFFB35C)),
            const SizedBox(width: 6),
            Text(
              c.dlnaName.isNotEmpty ? '正在投屏 · ${c.dlnaName}' : '正在投屏',
              style: TextStyle(color: Colors.white54, fontSize: t.body),
            ),
          ]),
        ],
      );
    }
    final info = c.getNowPlayingInfo();
    final current = c.currentProgram;
    final next = c.nextProgram;
    final hasChannel = c.currentChannel != null;
    // 电台：没有画面也没有 EPG，信息区要自己说清"在播音频"
    final isRadio = c.currentChannel?.isRadio ?? false;
    final radioGroup = isRadio ? (c.currentChannel?.groupTitle ?? '') : '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 大字：当前节目名（无 EPG 时显示频道名）
        Text(
          current?.title ?? (hasChannel ? info.channelName : '未选择频道'),
          style: TextStyle(
            color: Colors.white,
            fontSize: scale < 1 ? t.title - 2 : t.title,
            fontWeight: FontWeight.bold,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        SizedBox(height: scale < 1 ? 3 : 5),
        // 频道 / 分辨率 / 线路（电视直播不显示当前节目时段，
        // 时段只出现在下方「即将播放」那一行）
        Wrap(
          spacing: 10,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // 有 EPG 时大字行已是节目名，这里才需要频道名；
            // 无 EPG 时大字行本身就是频道名，避免重复
            if (hasChannel && current != null && !isRadio)
              _metaText(info.channelName, Colors.white70),
            // 电台：脉冲小条 + 「音频直播」，替代分辨率/线路这类视频信息
            if (isRadio)
              _audioBadge(c.isPlaying)
            else if (c.webPageActive) ...[
              // 网页频道：左边显示所选线路的分辨率（线路一 1080P → 1080P）
              _badge(c.webQualityLabel),
              _badge(
                  '线路 ${c.webQualityIndex + 1}/${c.webQualityLevels.length}'),
            ] else ...[
              // 普通直播源：取视频实际分辨率显示在左边
              if (c.resolutionText.isNotEmpty) _badge(c.resolutionText),
              _badge('线路 ${c.sourceIndex + 1}/${c.sourceCount}'),
            ],
          ],
        ),
        const SizedBox(height: 3),
        // 即将播放（保留结束时间）
        if (next != null)
          Text(
            '${_range(next)}  ${next.title}',
            style: TextStyle(color: Colors.white54, fontSize: t.body),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          )
        else if (isRadio)
          // 电台没有节目单：第三行放 ICY 实时曲目（有的话），
          // 没有就放分组名（电视伴音 / 央广·国家台 / …）
          AnimatedBuilder(
            animation: Listenable.merge([c.videoController]),
            builder: (context, _) {
              final icy =
                  (c.videoController?.value.mediaTitle ?? '').trim();
              final text = icy.isNotEmpty ? '♪ $icy' : radioGroup;
              if (text.isEmpty) return const SizedBox.shrink();
              return Text(
                text,
                style: TextStyle(
                  color: icy.isNotEmpty
                      ? Colors.white70
                      : AppColors.wave.withValues(alpha: 0.66),
                  fontSize: t.caption,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              );
            },
          )
        else if (!hasChannel)
          Text(
            '点击屏幕或 ≡ 按钮打开频道列表',
            style: TextStyle(color: Colors.white38, fontSize: t.caption),
          ),
      ],
    );
  }

  Widget _metaText(String text, Color color) {
    return Text(text,
        style: TextStyle(
            color: color,
            fontSize: AppTypography.of(context).body,
            fontWeight: FontWeight.w500));
  }

  /// 「音频直播」徽章：跳动的四根小条 + 文案，暂停时条压平、文案改「已暂停」
  Widget _audioBadge(bool playing) {
    final t = AppTypography.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.wave.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.wave.withValues(alpha: 0.32)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AudioBars(
              active: playing, height: 11, bars: 4, barWidth: 2.2, gap: 2.2),
          const SizedBox(width: 6),
          Text(
            playing ? '音频直播' : '已暂停',
            style: TextStyle(
              color: AppColors.wave,
              fontSize: t.caption,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _badge(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white30),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text,
          style: TextStyle(
              color: Colors.white70,
              fontSize: AppTypography.of(context).caption)),
    );
  }

  // ==================== 点播进度条 ====================

  Widget _buildSeekBar(PlayerController c) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: _SeekBar(controller: c, clock: _clock),
    );
  }

  // ==================== 控制按钮 ====================

  Widget _buildButtons(PlayerController c) {
    final hasChannel = c.currentChannel != null;
    // 电台没有画面：旋转/截图/录制无意义，置灰；播放/暂停仍可用
    final hasVideo = hasChannel && !(c.currentChannel?.isRadio ?? false);
    // 投屏态：播放会话由发送端控制，只保留必要操作
    if (c.isCasting) {
      final castActions = <_KbAction>[
        _KbAction(
            'playpause',
            c.isPlaying ? Icons.pause : Icons.play_arrow,
            c.isPlaying ? '暂停' : '播放',
            widget.onTogglePlayPause),
        if (c.isDesktop)
          _KbAction('mute', c.isMuted ? Icons.volume_off : Icons.volume_up,
              c.isMuted ? '取消静音' : '静音', c.toggleMute),
        _KbAction(
            'rotate',
            Icons.screen_rotation,
            c.videoRotation.value == 0
                ? '旋转画面'
                : (c.videoRotation.value == 3 ? '恢复原始方向' : '继续旋转 90°'),
            c.cycleVideoRotation),
        _KbAction('cast', Icons.cast_connected, '断开投屏',
            c.stopCastAndRestore),
      ];
      _actions = castActions;
      if (_kbId != null && !castActions.any((a) => a.id == _kbId)) {
        _kbId = null;
      }
      return Row(mainAxisSize: MainAxisSize.min, children: [
        for (final a in castActions) ...[
          _btn(a, big: a.id == 'playpause'),
          if (a.id == 'rotate') _groupDivider(AppDensity.of(context)),
        ],
      ]);
    }
    // 电台变体（方案 13.3）：音频没有画面，截图/旋转/小窗都不出现；
    // 睡前听广播高频，专给一个「定时关闭」
    final isRadio = c.currentChannel?.isRadio ?? false;
    final sleepRemain = c.sleepCountdown.value;
    // 可用动作：禁用按钮不进列表，遥控器只会高亮能点的按钮
    final actions = <_KbAction>[
      // 网页频道前台时切源键映射为清晰度循环（档位并入切源逻辑，
      // 遥控器左右键同路径），面板不单独设清晰度按钮
      _KbAction(
          'prevSource',
          Icons.skip_previous,
          c.webPageActive ? '降低清晰度' : '上一个源',
          c.hasPrevSource ? c.prevSource : null),
      _KbAction(
          'nextSource',
          Icons.skip_next,
          c.webPageActive ? '提升清晰度' : '下一个源',
          c.hasNextSource ? c.nextSource : null),
      _KbAction(
          'playpause',
          c.isPlaying ? Icons.pause : Icons.play_arrow,
          c.isPlaying ? '暂停' : '播放',
          hasChannel ? widget.onTogglePlayPause : null),
      if (isRadio) ...[
        // 电台录音（方案 12.3）：边听边录，流内直抓不转码
        _KbAction(
          'radioRec',
          c.isRadioRecording ? Icons.stop_rounded : Icons.fiber_manual_record,
          c.isRadioRecording ? '停止录音' : '录音',
          hasChannel ? c.toggleRadioRecord : null,
        ),
        _KbAction(
          'sleep',
          Icons.bedtime_outlined,
          sleepRemain == null
              ? '定时关闭'
              : '定时关闭（剩 ${_fmtRemain(sleepRemain)}）',
          () => _showSleepMenu(context),
        ),
      ],
      if (c.isDesktop && !isRadio) ...[
        _KbAction('screenshot', Icons.camera_alt, '截图',
            hasVideo ? widget.onScreenshot : null),
        _KbAction(
            'record',
            c.isRecording ? Icons.stop_rounded : Icons.fiber_manual_record,
            c.isRecording ? '停止录制' : '开始录制',
            hasVideo ? widget.onToggleRecord : null),
      ],
      // 顺序必须与界面从左到右一致：旋转在小窗/静音/全屏之前，
      // 否则遥控器 ←/→ 会在「全屏 ↔ 旋转 ↔ 小窗」之间来回跳
      if (!isRadio)
        _KbAction(
            'rotate',
            Icons.screen_rotation,
            c.videoRotation.value == 0
                ? '旋转画面'
                : (c.videoRotation.value == 3 ? '恢复原始方向' : '继续旋转 90°'),
            hasVideo ? c.cycleVideoRotation : null),
      // 静音 / 全屏（与 OMTV 底部栏一致，鼠标直接可点）
      if (c.isDesktop) ...[
        _KbAction(
            'mute',
            c.isMuted ? Icons.volume_off : Icons.volume_up,
            c.isMuted ? '取消静音' : '静音',
            c.toggleMute),
        _KbAction(
            'fullscreen',
            c.isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
            c.isFullscreen ? '退出全屏' : '全屏',
            c.toggleFullscreen),
      ],
      // 手动重载当前频道：网页卡死/黑屏时不必等自动看门狗；
      // 投屏中播放会话由发送端控制，重载无意义（置灰），
      // 断开投屏后自动恢复可用
      if (widget.onReload != null)
        _KbAction(
            'reload',
            Icons.refresh,
            c.isCasting ? '重载频道（投屏中不可用）' : '重载频道',
            c.isCasting ? null : widget.onReload),
      // 网页/内置切换：仅网页频道体系内可用——网页播放中可切内置流
      // 播放（需已嗅探到可直连流），接管后可切回网页；纯流频道不显示
      if (c.showWebNativeButton)
        _KbAction(
          'webnative',
          c.webPageActive ? Icons.smart_display : Icons.language,
          c.webPageActive ? '内置播放器播放' : '网页播放器播放',
          c.canToggleWebNative ? widget.onSwitchWebNative : null,
        ),
      if (c.isCasting)
        _KbAction('cast', Icons.cast_connected, '断开投屏',
            c.stopCastAndRestore),
    ];
    _actions = actions;
    // 当前高亮的动作若已消失（如断开投屏），清除高亮，等下次方向键重选
    if (_kbId != null && !actions.any((a) => a.id == _kbId)) _kbId = null;

    final d = AppDensity.of(context);

    void addByIdTo(List<Widget> out, String id) {
      final i = actions.indexWhere((a) => a.id == id);
      if (i >= 0) out.add(_btn(actions[i]));
    }

    // 分组：换源 | 播放 | 截录旋转 | 静音全屏 | 重载/切换/投屏
    // 组间用竖线分隔（电视/桌面档），组内紧凑
    _KbAction byId(String id) => actions.firstWhere((a) => a.id == id);
    final children = <Widget>[
      SourceStepper(
        // 网页频道：清晰度档位归入线路体系（线路一 = 最高档 1080P），
        // 菜单可直选某条线路；普通频道：线路 = 频道的多源列表
        index: c.webPageActive ? c.webQualityIndex : c.sourceIndex,
        count: c.webPageActive ? c.webQualityLevels.length : c.sourceCount,
        onPrev: byId('prevSource').onPressed,
        onNext: byId('nextSource').onPressed,
        onSelect: c.webPageActive
            ? (i) => c.selectWebQuality(i)
            : (i) => c.switchSource(i),
        webLines: c.webPageActive
            ? [for (final l in c.webQualityLevels) '${l}P']
            : null,
        prevSelected: _kbId == 'prevSource',
        nextSelected: _kbId == 'nextSource',
      ),
      _groupDivider(d),
      _btn(byId('playpause'), big: true),
      _groupDivider(d),
    ];
    if (c.isDesktop && !isRadio) {
      children.addAll([
        _btn(byId('screenshot')),
        _btn(byId('record'), big: true),
      ]);
    }
    if (!isRadio) children.add(_btn(byId('rotate')));
    children.add(_groupDivider(d));

    void addById(String id) {
      final i = actions.indexWhere((a) => a.id == id);
      if (i >= 0) children.add(_btn(actions[i]));
    }

    addById('mute');
    addById('fullscreen');

    // 尾部功能组：重载 / 网页切换 / 断开投屏（有则加竖线）
    final tail = <Widget>[];
    addByIdTo(tail, 'reload');
    addByIdTo(tail, 'webnative');
    addByIdTo(tail, 'cast');
    if (tail.isNotEmpty) {
      children.add(_groupDivider(d));
      children.addAll(tail);
    }

    // 电台录音（电台专属）：边听边录，放尾部与高频操作隔开
    if (isRadio) {
      children.add(_groupDivider(d));
      children.add(_btn(byId('radioRec')));
    }

    // 定时关闭独占最末位（电台专属）：跟换台/播放这些高频操作隔开，
    // 睡前设一次就不容易被误碰
    if (isRadio) {
      children.add(_groupDivider(d));
      children.add(_btn(byId('sleep')));
    }

    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }

  /// 剩余时间文案：1:05:00 / 32:10
  static String _fmtRemain(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final sec = d.inSeconds % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
    }
    return '$m:${sec.toString().padLeft(2, '0')}';
  }

  /// 定时关闭菜单：30/60/90 分钟、取消定时。
  /// 只暂停播放不退出——听着睡着的人第二天还想接着听。
  Future<void> _showSleepMenu(BuildContext context) async {
    final c = context.read<PlayerController>();
    final remain = c.sleepRemain;
    final picked = await showDialog<int>(
      context: context,
      barrierColor: AppColors.scrim,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.overlay,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppColors.stroke),
        ),
        title: const Text('定时关闭',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              remain == null ? '到点自动暂停播放' : '剩余 ${_fmtRemain(remain)}',
              style:
                  const TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
            ),
            const SizedBox(height: 10),
            for (final m in const [30, 60, 90])
              ListTile(
                dense: true,
                title: Text('$m 分钟后',
                    style: const TextStyle(
                        color: AppColors.textPrimary, fontSize: 14)),
                onTap: () => Navigator.pop(ctx, m),
              ),
            if (remain != null)
              ListTile(
                dense: true,
                title: const Text('取消定时',
                    style: TextStyle(color: AppColors.live, fontSize: 14)),
                onTap: () => Navigator.pop(ctx, 0),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    c.setSleepTimer(picked == 0 ? null : Duration(minutes: picked));
  }

  /// 面板按钮：统一走 [GhostButton]（全 App 唯一圆形操作钮）。
  ///
  /// 遥控器高亮走 `selected`（与键盘/悬停同一套白描边视觉），
  /// 不再有"蓝底方框"这种第二种高亮样式。
  Widget _btn(_KbAction a, {bool big = false}) {
    final selected = a.id == _kbId;
    final role = big ? GhostButtonRole.emphasis : GhostButtonRole.normal;

    // 旋转按钮的颜色随旋转状态变化，单独保留 ValueListenableBuilder
    if (a.id == 'rotate') {
      return ValueListenableBuilder<int>(
        valueListenable: context.read<PlayerController>().videoRotation,
        builder: (context, rot, _) => GhostButton(
          icon: Icons.screen_rotation,
          tooltip: _withHotkey(a),
          onPressed: a.onPressed,
          selected: selected,
          role: role,
          iconColor: rot == 0 ? Colors.white70 : Colors.amber,
        ),
      );
    }

    // 状态色：录制中红点、断开投屏红；其余保持白色
    Color? iconColor;
    if (a.id == 'record') {
      iconColor = a.tooltip.contains('停止') ? Colors.redAccent : null;
    } else if (a.id == 'cast') {
      iconColor = Colors.redAccent;
    }

    return GhostButton(
      icon: a.icon,
      tooltip: _withHotkey(a),
      onPressed: a.onPressed,
      selected: selected,
      role: role,
      iconColor: iconColor,
    );
  }

  /// 桌面端在提示后追加真实快捷键（第 8 步：键位与实际分发保持一致，
  /// 只标注确实已注册的键，避免提示写了按不出来）
  static const Map<String, String> _hotkeys = {
    'playpause': '空格',
    'fullscreen': 'F',
    'mute': 'M',
    'record': 'R',
  };

  String _withHotkey(_KbAction a) {
    final key = _hotkeys[a.id];
    if (key == null) return a.tooltip;
    if (!context.read<PlayerController>().isDesktop) return a.tooltip;
    return '${a.tooltip} ($key)';
  }

  /// 分组竖线：电视/桌面显示，手机档不画（5 钮连线显碎）
  Widget _groupDivider(AppDensity d) {
    if (!d.useDividers) return SizedBox(width: d.interGroupGap * 0.5);
    return Container(
      width: 1,
      height: 26,
      margin: EdgeInsets.symmetric(horizontal: d.interGroupGap * 0.5),
      color: Colors.white.withOpacity(0.10),
    );
  }

  static final _hm = DateFormat('HH:mm');

  String _range(EpgProgram p) =>
      '${_hm.format(p.startTime)} - ${_hm.format(p.endTime)}';
  String _clock(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

/// 点播进度条。
///
/// 拖动过程中只更新本地预览位置，【松手时】(onChangeEnd) 才真正 seek：
/// Slider.onChanged 在一次拖动中会连续回调几十次，若每次都 seekTo，
/// 会反复打断播放内核对长视频远距位置的缓冲（投屏长视频拖动时表现为
/// 画面卡死、随后被看门狗判定缓冲超时而销毁重建）。
class _SeekBar extends StatefulWidget {
  final PlayerController controller;
  final String Function(Duration) clock;

  const _SeekBar({required this.controller, required this.clock});

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  /// 拖动中的预览位置（毫秒）；未拖动时为 null，跟随实际播放位置
  double? _dragMs;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final total = c.duration;
    final max = total.inMilliseconds.toDouble();
    final safeMax = max <= 0 ? 1.0 : max;
    final pos = _dragMs ??
        c.position.inMilliseconds.clamp(0, safeMax.round()).toDouble();
    final value = pos.clamp(0, safeMax).toDouble();
    return Row(
      children: [
        Text(widget.clock(Duration(milliseconds: value.round())),
            style: TextStyle(
                color: Colors.white70,
                fontSize: AppTypography.of(context).caption - 1.5)),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              thumbShape:
                  const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape:
                  const RoundSliderOverlayShape(overlayRadius: 12),
              activeTrackColor: Colors.blueAccent,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.blueAccent,
            ),
            child: Slider(
              value: value,
              max: safeMax,
              onChangeStart: (v) => setState(() => _dragMs = v),
              onChanged: (v) => setState(() => _dragMs = v),
              onChangeEnd: (v) {
                c.seekTo(Duration(milliseconds: v.round()));
                setState(() => _dragMs = null);
              },
            ),
          ),
        ),
        Text(widget.clock(total),
            style: TextStyle(
                color: Colors.white70,
                fontSize: AppTypography.of(context).caption - 1.5)),
      ],
    );
  }
}
