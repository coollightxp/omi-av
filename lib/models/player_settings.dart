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
  /// 停顿超过该时间才真正切到预览的台。500 快切 / 800 / 1200 / 2000 / 2500（默认）/ 3000。
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

  /// F9 摸鱼快捷键开关（默认开）：开着按 F9 进入/退出摸鱼
  /// （静音并隐藏窗口）；关着 F9 不响应，只能用托盘菜单进出摸鱼。
  /// 注意开关本身只控制快捷键，不会立刻隐藏窗口——进出动作由 F9/托盘触发。
  final bool fishHotkey;

  /// 底部面板是否显示「网页播放器/内置播放器切换」按钮。
  /// 默认关：该按钮很不常用（网页频道嗅探接管场景），常驻面板反而
  /// 挤占遥控器焦点路径（用户要求收进设置，开关控制显隐）
  final bool showWebNativeToggle;

  /// 电台逐句歌词（默认关，待办 L）。
  ///
  /// 开着时：播电台若推了 ICY 曲名，自动拿曲名去 LRCLIB 查歌词并显示
  /// 逐句滚动；没曲名的台不拉取、不显示。关掉则功能完全不存在。
  final bool lyricsEnabled;

  /// 歌词时间微调（毫秒，正 = 歌词整体延后、负 = 提前）。
  /// 电台推曲名偏早或前奏长时，歌词会比人声快半拍，这里整体挪一下；
  /// 步进 0.5s，范围 ±10s（`PlayerController.setLyricsOffset` 夹紧）
  final int lyricsOffsetMs;

  /// 歌词简繁转换（0 = 原文，1 = 转简体，2 = 转繁体）。
  /// 很多词源只放繁体 LRC，转成简体好认；喜欢繁体的也能把简体歌词
  /// 转成繁体看。词组优先转换（OpenCC 词表随包发布），避免
  /// 「头发→頭發」这类一简对多繁的错字
  final int lyricsVariant;

  /// 列表里隐藏「探测确认不可用」的内置源频道（默认开）。
  /// 只影响内置电台精选——死台源在清单里保留，恢复后自动回到列表
  final bool hideUnavailableChannels;

  /// 预约到点自动录音（默认关）：预约开始时除了切台，还自动开始录制。
  /// 单条预约仍可单独勾选「自动录制」，这里是全局开关
  final bool reservationRecord;

  /// 录制/录音保存目录（空 = 用默认：桌面端程序目录、安卓应用文档目录）。
  /// 只对桌面端生效，安卓路径固定
  final String recordSaveDir;

  /// 投屏录制全速下载（默认关 = 按 1.5 倍速限速）。
  /// 打开后满速拉取，整片更快下完，但会和播放器抢带宽
  final bool castRecordFullSpeed;

  const PlayerSettings({
    this.autoPlayNext = true,
    this.defaultVolume = 0.8,
    this.defaultBrightness = 0.8,
    this.preferredQuality = VideoQuality.auto,
    this.gestureSensitivity = 1.0,
    this.autoHideDelay = 3000,
    this.tuneDwellMs = 2500,
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
    this.fishHotkey = true,
    this.showWebNativeToggle = false,
    this.lyricsEnabled = false,
    this.lyricsOffsetMs = 0,
    this.lyricsVariant = 0,
    this.hideUnavailableChannels = true,
    this.reservationRecord = false,
    this.recordSaveDir = '',
    this.castRecordFullSpeed = false,
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
    bool? fishHotkey,
    bool? showWebNativeToggle,
    bool? lyricsEnabled,
    int? lyricsOffsetMs,
    int? lyricsVariant,
    bool? hideUnavailableChannels,
    bool? reservationRecord,
    String? recordSaveDir,
    bool? castRecordFullSpeed,
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
      fishHotkey: fishHotkey ?? this.fishHotkey,
      showWebNativeToggle: showWebNativeToggle ?? this.showWebNativeToggle,
      lyricsEnabled: lyricsEnabled ?? this.lyricsEnabled,
      lyricsOffsetMs: lyricsOffsetMs ?? this.lyricsOffsetMs,
      lyricsVariant: lyricsVariant ?? this.lyricsVariant,
      hideUnavailableChannels:
          hideUnavailableChannels ?? this.hideUnavailableChannels,
      reservationRecord: reservationRecord ?? this.reservationRecord,
      recordSaveDir: recordSaveDir ?? this.recordSaveDir,
      castRecordFullSpeed:
          castRecordFullSpeed ?? this.castRecordFullSpeed,
    );
  }
}

/// 声音实验室预设（方案 12.3 第二档）：mpv lavfi 音频滤镜串。
/// 「标准 / 原声无损」为空（清除滤镜），不进表。

enum VideoQuality {
  auto('自动'),
  low('标清 480p'),
  medium('高清 720p'),
  high('全高清 1080p'),
  ultra('超清 4K');

  final String label;
  const VideoQuality(this.label);
}
