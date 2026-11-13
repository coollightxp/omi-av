/// 播放器设置
class PlayerSettings {
  /// 自动播放下一个频道
  final bool autoPlayNext;

  /// 默认音量 (0.0 - 1.0)
  final double defaultVolume;

  /// 默认亮度 (0.0 - 1.0)
  final double defaultBrightness;

  /// 视频质量偏好
  final VideoQuality preferredQuality;

  /// 手势灵敏度 (0.5 - 2.0)
  final double gestureSensitivity;

  /// 面板自动隐藏延迟（毫秒）
  final int autoHideDelay;

  /// 换台停留（毫秒）：↑/↓ 连续按键时只更新左上角预览、继续播当前台，
  /// 停顿超过该时间才真正切到预览的台。500 快切 / 800 / 1200 / 2000。
  final int tuneDwellMs;

  /// 开机自启动
  final bool launchAtStartup;

  /// 启动即进入全屏（仅在程序启动时检测一次）
  final bool startFullscreen;

  /// 右上角常驻显示系统时间
  final bool showClock;

  /// 窗口置顶（仅桌面端，默认开：保证快捷键焦点不被其它窗口抢走）
  final bool alwaysOnTop;

  /// DLNA 投屏接收服务开关（默认开）
  final bool dlnaEnabled;

  /// 单个播放源起播等待秒数：超时后自动切换下一个源（默认 5 秒，5 秒一档）
  final int sourceTimeoutSeconds;

  /// 播放缓冲秒数：网络抖动时的预读缓冲上限（5/10/20/30 秒，默认 5 秒）。
  /// 由 MDK 后端在启动时应用，修改后重启程序生效
  final int bufferSeconds;

  /// 界面字体缩放（1.0 = 系统默认；4K/8K 大屏可调到 1.5~3.0）
  final double uiScale;

  /// 字体缩放自动适配屏幕分辨率（开启后按屏幕宽度自动计算，忽略 uiScale）
  final bool uiScaleAuto;

  /// 局域网 Web 管理服务开关（手机扫码管理直播源/EPG）
  final bool remoteAdminEnabled;

  /// 网页直播支持开关（默认开）。
  /// 关闭后启动时不清理/不创建 WebView2 运行时环境，网页频道
  /// （webview:// 源）不可用——用于不支持 WebView2 的系统避免退出崩溃
  final bool webEnabled;

  /// 失败自动重载（默认开）：网页频道播放位置连续 24 秒不推进时自动重载；
  /// 内置播放器起播/播放失败时自动重试当前频道。重试次数由
  /// [retryTimes] 决定，次数用尽仍失败则提示链接失效
  final bool autoReloadStall;

  /// 自动重载/重试次数（3/5/10，默认 3）：每个频道连续失败达到该次数后
  /// 判定链接失效，不再自动重试（手动切台或点重试会清零重新计数）
  final int retryTimes;

  /// 投屏结束后（播完或发送端停止）的处理（秒）：
  /// 0=立即返回直播；60/300/600=进入「正在等待投屏」，期间发送端连播
  /// （电视剧下一集）可直接接上；超时未等到新投屏才返回直播；
  /// -1=一直等待，直到新投屏到来或用户双击返回/手动切台。
  /// 方案 3.7 五档。
  final int castEndWaitSeconds;

  /// 定时关闭到点做什么（跨启动记住）：
  /// - 'pause'：暂停播放，程序留着（听电台睡着，第二天接着听）
  /// - 'exit'：退出应用（看电视睡着，没必要挂一整夜）
  /// - 'shutdown'：退出应用并关闭电脑（桌面端，睡前看片常用）
  final String sleepActionKey;

  /// 定时关闭的目标时刻（epoch 毫秒，0 = 未设定）。
  /// 持久化后重启仍能续上；启动时若已过期自动清除。
  final int sleepAtMs;

  /// 启动时恢复上次频道（默认开）。
  /// 关闭后启动进入「待选台」画面，不发起任何网络请求，
  /// 按 OK/方向键/点屏幕才打开频道列表。方案第九节。
  final bool resumeLastChannel;

  /// 关闭按钮最小化到托盘（桌面端，默认关）：开着时点 ✕ 窗口隐藏、
  /// 继续播放（托盘图标可恢复/退出）；关着时 ✕ 直接退出。
  /// 「后台播放」随时可用：底部面板「后台」按钮把窗口缩到托盘只听声。
  final bool closeToTray;

  /// 声音实验室预设（方案 12.3 第二档）：'' = 标准；key 见 kAudioPresets。
  /// 走 mpv lavfi 音频滤镜，仅内置播放器生效（网页播放器不支持）。
  /// 'custom' = 自定义 10 段均衡器，增益见 [audioEqGains]
  final String audioPreset;

  /// 自定义均衡器 10 段增益（dB，-12~+12），中心频率
  /// 31/62/125/250/500/1k/2k/4k/8k/16k；空表 = 全 0（直通）
  final List<double> audioEqGains;

  /// 电台「真波形纹理」实验开关（默认关）。
  /// 开着时让 mpv 用 lavfi-complex 把音频画成视频帧贴出来（真实波形，
  /// 但会占 vo，部分流的滤镜链建不起来）；关着走 Flutter 侧电平波形，
  /// 稳定且不黑屏。绝大多数用户不需要开。
  final bool spectrumTexture;

  /// 播放内核（'mpv' / 'mdk'，默认 mdk）。
  ///
  /// - mdk：fvp + libmdk（D3D11 直出纹理），画面最稳，老显卡/1607 上
  ///   叠加面板不闪黑；均衡器与真电平波形不生效（波形自动退回模拟）
  /// - mpv：media_kit + libmpv，功能最全（滤镜/录制/电平/截帧），但个别
  ///   老显卡在面板动画时会闪一下
  ///
  /// 2026-11 用户实测：同机 MPV 闪黑、MDK 不闪，故默认取 MDK；MPV 保留
  /// 作回退（设置可切，MDK 起播失败也会自动回落）
  /// 切换后换台生效（当前画面不会热切）
  final String playEngine;

  /// 电台「真实电平波形」开关（默认关）。
  ///
  /// 开着时在 mpv 的 `af` 链上串一条 `astats` 电平表，波形跟着真实响度走；
  /// 关着时波形按播放态动画，**完全不碰音频链**。
  /// 2026-11 用户实测：Win10 1607 上挂这条滤镜后电台整路无声（视频不受
  /// 影响，因为视频不挂滤镜），所以默认关闭；想要真波形的用户可在
  /// 「在线电台」页签里自行开启，出现无声直接关掉即可。
  final bool radioMeter;

  const PlayerSettings({
    this.autoPlayNext = true,
    this.defaultVolume = 0.8,
    this.defaultBrightness = 0.8,
    this.preferredQuality = VideoQuality.auto,
    this.gestureSensitivity = 1.0,
    this.autoHideDelay = 3000,
    this.tuneDwellMs = 1200,
    this.launchAtStartup = false,
    this.startFullscreen = false,
    this.showClock = false,
    this.alwaysOnTop = true,
    this.dlnaEnabled = true,
    this.sourceTimeoutSeconds = 5,
    this.bufferSeconds = 5,
    this.uiScale = 1.0,
    this.uiScaleAuto = true,
    this.remoteAdminEnabled = true,
    this.webEnabled = true,
    this.autoReloadStall = true,
    this.retryTimes = 3,
    this.castEndWaitSeconds = 0,
    this.sleepActionKey = 'pause',
    this.sleepAtMs = 0,
    this.resumeLastChannel = true,
    this.closeToTray = false,
    this.audioPreset = '',
    this.audioEqGains = const <double>[],
    this.spectrumTexture = false,
    this.radioMeter = false,
    this.playEngine = 'mdk',
  });

  PlayerSettings copyWith({
    bool? autoPlayNext,
    double? defaultVolume,
    double? defaultBrightness,
    VideoQuality? preferredQuality,
    double? gestureSensitivity,
    int? autoHideDelay,
    int? tuneDwellMs,
    bool? launchAtStartup,
    bool? startFullscreen,
    bool? showClock,
    bool? alwaysOnTop,
    bool? dlnaEnabled,
    int? sourceTimeoutSeconds,
    int? bufferSeconds,
    double? uiScale,
    bool? uiScaleAuto,
    bool? remoteAdminEnabled,
    bool? webEnabled,
    bool? autoReloadStall,
    int? retryTimes,
    int? castEndWaitSeconds,
    String? sleepActionKey,
    int? sleepAtMs,
    bool? resumeLastChannel,
    bool? closeToTray,
    String? audioPreset,
    List<double>? audioEqGains,
    bool? spectrumTexture,
    bool? radioMeter,
    String? playEngine,
  }) {
    return PlayerSettings(
      autoPlayNext: autoPlayNext ?? this.autoPlayNext,
      defaultVolume: defaultVolume ?? this.defaultVolume,
      defaultBrightness: defaultBrightness ?? this.defaultBrightness,
      preferredQuality: preferredQuality ?? this.preferredQuality,
      gestureSensitivity: gestureSensitivity ?? this.gestureSensitivity,
      autoHideDelay: autoHideDelay ?? this.autoHideDelay,
      tuneDwellMs: tuneDwellMs ?? this.tuneDwellMs,
      launchAtStartup: launchAtStartup ?? this.launchAtStartup,
      startFullscreen: startFullscreen ?? this.startFullscreen,
      showClock: showClock ?? this.showClock,
      alwaysOnTop: alwaysOnTop ?? this.alwaysOnTop,
      dlnaEnabled: dlnaEnabled ?? this.dlnaEnabled,
      sourceTimeoutSeconds:
          sourceTimeoutSeconds ?? this.sourceTimeoutSeconds,
      bufferSeconds: bufferSeconds ?? this.bufferSeconds,
      uiScale: uiScale ?? this.uiScale,
      uiScaleAuto: uiScaleAuto ?? this.uiScaleAuto,
      remoteAdminEnabled: remoteAdminEnabled ?? this.remoteAdminEnabled,
      webEnabled: webEnabled ?? this.webEnabled,
      autoReloadStall: autoReloadStall ?? this.autoReloadStall,
      retryTimes: retryTimes ?? this.retryTimes,
      castEndWaitSeconds: castEndWaitSeconds ?? this.castEndWaitSeconds,
      sleepActionKey: sleepActionKey ?? this.sleepActionKey,
      sleepAtMs: sleepAtMs ?? this.sleepAtMs,
      resumeLastChannel: resumeLastChannel ?? this.resumeLastChannel,
      closeToTray: closeToTray ?? this.closeToTray,
      audioPreset: audioPreset ?? this.audioPreset,
      audioEqGains: audioEqGains ?? this.audioEqGains,
      spectrumTexture: spectrumTexture ?? this.spectrumTexture,
      radioMeter: radioMeter ?? this.radioMeter,
      playEngine: playEngine ?? this.playEngine,
    );
  }
}

/// 声音实验室预设（方案 12.3 第二档）：mpv lavfi 音频滤镜串。
/// 「标准」为空（清除滤镜），不进表。
const Map<String, String> kAudioPresets = {
  // 人声增强：压 250Hz 鼻音/轰鸣，提 3kHz 人声主区
  'voice': 'equalizer=f=250:t=q:w=1.4:g=-3,equalizer=f=3000:t=q:w=1.2:g=4',
  // 低音增强：80/160Hz 双点提升
  'bass': 'equalizer=f=80:t=q:w=1.2:g=6,equalizer=f=160:t=q:w=1.2:g=3',
  // 夜间模式：动态响度归一，音量忽大忽小被抹平，睡觉听不打醒
  'night': 'dynaudnorm=f=250:g=15:p=0.9',
};

enum VideoQuality {
  auto('自动'),
  low('标清 480p'),
  medium('高清 720p'),
  high('全高清 1080p'),
  ultra('超清 4K');

  final String label;
  const VideoQuality(this.label);
}
