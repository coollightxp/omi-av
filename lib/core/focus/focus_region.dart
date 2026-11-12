/// 焦点区域枚举：全 App 所有可能持有焦点的区域。
///
/// [player] 是栈底常驻区域；其余区域通过 FocusCoordinator.push 压栈获得
/// 按键主权，pop 后交还。
enum FocusRegion {
  /// 播放器本体（栈底常驻）：换台/换源/呼出面板
  player,

  /// 左侧频道列表面板
  channelList,

  /// 右侧 EPG 面板
  epg,

  /// 底部信息/控制条
  bottomPanel,

  /// 退出卡片（模态）
  exitCard,

  /// 数字输台（覆盖 player 的输入态）
  numberInput,

  /// 线路选择菜单
  lineMenu,

  /// 设置中心（模态）
  settings,

  /// 源管理对话框（showDialog 模态，含删除二段确认）
  sourceDialog,

  /// 声音实验室（均衡器等，模态浮层）
  soundLab,

  /// 录音库（模态浮层）
  recordingLibrary,
}
