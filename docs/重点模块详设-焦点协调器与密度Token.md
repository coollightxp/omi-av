# 重点模块详设：焦点协调器 与 密度/字号 Token

> 两个最高优先级模块的完整设计说明：为什么这么设计、代码长什么样、怎么一步步接入、怎么验收。
> 本文档是《欧米直播改造方案.md》《改造方案-实施细则.md》中这两个模块的展开版，以本文为准。

---

# 模块一：焦点协调器（FocusCoordinator）

## 1.1 解决的三个顽疾

| 症状（现状） | 根因 | 协调器对策 |
|---|---|---|
| 焦点穿透：面板开着按 OK，面板和播放器同时动作 | 按键事件向上冒泡，面板处理了但没返回 `handled` | 全 App 唯一按键分发点，派给一个区即终止 |
| 焦点丢失：面板开着方向键没反应 | 各面板各自管焦点，互相不知情 | 焦点永远属于某个注册过的 Region，不存在无主状态 |
| 焦点不回原位：关面板后跳回列表第一项 | 关闭时 reset 而非恢复 | 打开时存档，关闭时精确恢复 |

## 1.2 设计要点：Region 栈，而不是单值

面板会叠加（频道列表开着 → 又弹出退出卡片），所以协调器内部维护**栈**：

```
push(区域)   = 面板打开：当前区压栈，焦点交给新面板，存档旧焦点
pop()        = 面板关闭：弹栈，焦点还给上一层的存档节点
peek()       = 当前生效区域（按键分发依据）
```

按键分发只看栈顶。下层区域在栈顶存在期间**收不到任何按键**——穿透在结构上不可能发生。

## 1.3 文件结构

```
lib/core/focus/
├── focus_region.dart       # 区域枚举 + 区域元信息
├── focus_coordinator.dart  # 总管（单例，ChangeNotifier）
└── safe_focus.dart         # safeRequestFocus 工具
```

## 1.4 核心代码骨架

```dart
// focus_region.dart
enum FocusRegion {
  player,        // 播放器本体（栈底常驻）
  channelList,   // 左侧频道列表
  epg,           // 右侧 EPG 面板
  bottomPanel,   // 底部信息/控制条
  exitCard,      // 退出卡片
  numberInput,   // 数字输台（覆盖 player 的输入态）
  lineMenu,      // 线路选择菜单
}
```

```dart
// focus_coordinator.dart
class FocusCoordinator extends ChangeNotifier {
  final List<FocusRegion> _stack = [FocusRegion.player];
  final Map<FocusRegion, FocusNode?> _archive = {}; // 每层打开前的焦点存档

  FocusRegion get current => _stack.last;
  bool get isOnPlayer => _stack.length == 1;

  /// 面板打开
  void push(FocusRegion region, {required FocusNode initialFocus}) {
    // 给"即将被覆盖的层"存档：记住它当时持有的焦点节点
    _archive[_stack.last] = FocusManager.instance.primaryFocus;
    _stack.add(region);
    safeRequestFocus(initialFocus);
    notifyListeners();
  }

  /// 面板关闭
  void pop() {
    assert(_stack.length > 1, 'player 是栈底，不可 pop');
    final closed = _stack.removeLast();
    _archive.remove(closed);
    final restore = _archive[_stack.last];
    if (restore != null) safeRequestFocus(restore);
    notifyListeners();
  }

  /// 全 App 唯一按键入口：挂在最外层 FocusScope 的 onKeyEvent
  KeyEventResult onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored; // 只处理按下
    switch (current) {
      case FocusRegion.player:      return _playerKey(event);
      case FocusRegion.channelList: return _listKey(event);
      case FocusRegion.epg:         return _epgKey(event);
      case FocusRegion.bottomPanel: return _panelKey(event);
      case FocusRegion.exitCard:    return _exitCardKey(event);
      case FocusRegion.numberInput: return _numberKey(event);
      case FocusRegion.lineMenu:    return _menuKey(event);
    }
  }
  // 每个 _xxxKey 返回 KeyEventResult.handled（除非明确要放行给系统）
}
```

```dart
// safe_focus.dart
void safeRequestFocus(FocusNode node) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (node.context != null) node.requestFocus(); // 未挂载则跳过，防静默失败
  });
}
```

**播放器分支内嵌防抖换台**（上下键）：

```dart
KeyEventResult _playerKey(KeyEvent event) {
  final key = event.logicalKey;
  if (key == LogicalKeyboardKey.arrowUp)   { _tune(+1); return handled; }
  if (key == LogicalKeyboardKey.arrowDown) { _tune(-1); return handled; }
  if (key == LogicalKeyboardKey.arrowLeft) { player.switchSource(-1); return handled; }
  if (key == LogicalKeyboardKey.arrowRight){ player.switchSource(+1); return handled; }
  if (key == LogicalKeyboardKey.select)    { push(channelList, ...); return handled; }
  if (key == LogicalKeyboardKey.back)      { showExitCard(); return handled; }
  return ignored; // 数字键等交给上层转 numberInput
}
```

## 1.5 各面板接入步骤（每步可编译可运行）

| 步骤 | 动作 | 验收 |
|---|---|---|
| ① | 搭建协调器 + App 外层挂 onKeyEvent，此时只有 player 分支 | 播放器方向键行为与旧版一致 |
| ② | 接入频道列表：面板 init 时 `push(channelList, ...)`，dispose 时 `pop()`；**删除该面板内所有自有 onKeyEvent / requestFocus** | 列表开关 20 次，无穿透、焦点回原频道 |
| ③ | 同法接入 EPG 面板（含预约键） | 同上 |
| ④ | 同法接入底部面板 | 同上 |
| ⑤ | 同法接入退出卡片（返回键在 player 分支触发它） | 卡片上按返回=关卡片不是退出 |
| ⑥ | 数字输入：player 分支检测到数字键 → `push(numberInput)`，输入完成/超时/取消 → `pop()` | 输错重输、返回键取消输入 |
| ⑦ | 线路菜单：步进器 chip 打开时 `push(lineMenu)` | 菜单开着时左右键不会换台 |

**每接入一个面板必须删除的东西（迁移即还债）**：
- 面板内 `onKeyEvent` / `KeyboardListener` / `Shortcuts` 自定义按键处理
- 面板内自发 `requestFocus`（改由 push 的 initialFocus 提供）
- 旧代码里"打开 A 时手动把 B 的焦点移走"之类的胶水逻辑

## 1.6 验收测试（做完跑一遍，以后每次改动回归）

1. 随机顺序"开面板→返回→开另一个→返回"× 20：每个方向键恰好一个动作
2. 从频道列表第 N 项开 EPG 再关闭：焦点回第 N 项
3. 数字输入中途按返回：输入取消，不弹退出卡片
4. 线路菜单打开时按←→：移动菜单焦点，不切换线路
5. 连续按上下 10 次：只触发 1 次切流（防抖生效），OSD 跟随每次按键

---

# 模块二：密度/字号 Token（三层缩放体系）

## 2.1 三层模型

```
第 1 层 设备档（全自动）    Windows→桌面档  电视→电视档  其他→手机档
第 2 层 安卓设备模式（半自动）设置项：自动/手机平板/电视，决定安卓用哪档
第 3 层 用户滑块（手动）    0.85–1.30 乘数，全局等比
最终值 = 基准档数值 × 滑块系数
```

## 2.2 文件结构

```
lib/core/theme/
├── app_colors.dart       # 颜色（面板底色、三级文字色、主题色、发光色）
├── app_typography.dart   # 语义字号槽 × 三档
├── app_density.dart      # 尺寸/间距 token × 三档
└── device_profile.dart   # 设备档判定 + 安卓模式开关读取
lib/core/settings/
└── display_settings.dart # 滑块值存取（shared_preferences）
```

## 2.3 完整数值表（定稿）

### 字号（app_typography，sp）

| 语义槽 | 电视 | 桌面 | 手机 |
|---|---|---|---|
| 频道名/标题 title | 18 | 15 | 13 |
| 正文/节目 body | 15 | 13 | 10.5 |
| 辅助/技术信息 caption | 13 | 11 | —（手机砍） |
| OSD 频道号大数字 osdNumber | 26 | 20 | 17 |
| OSD 台名 | =title | =title | =title |
| OSD 辅助行 | 14 | 12 | =caption |

### 尺寸（app_density，dp）

| 语义 | 电视 | 桌面 | 手机 |
|---|---|---|---|
| 底部面板总高 | 78 | 66 | 54 |
| 面板左右内边距 | 20 | 16 | 12 |
| 台标尺寸 / 台标→文字距 | 44 / 14 | 38 / 12 | 32 / 10 |
| ghost 按钮直径 | 44 | 38 | 35 |
| 组内按钮距 / 组间距 | 10/28 | 8/28 | 8/24 |
| 分组竖线 | 有 | 有 | **无** |
| 频道列表行高 | 62 | 50 | 41 |
| 信息区↔操作区最小距 | 40 | 32 | 24 |

### 按钮"倍率"（组件内写死，不开放传参）

主控钮（播放/暂停）×1.2 · TV 焦点态 ×1.05 + 发光 · 带标签按钮整体乘滑块系数

## 2.4 核心代码骨架

```dart
// device_profile.dart
enum DeviceProfile { tv, desktop, mobile }

DeviceProfile resolveProfile(Settings s) {
  if (Platform.isWindows) return DeviceProfile.desktop;
  if (!Platform.isAndroid) return DeviceProfile.mobile;
  switch (s.androidDeviceMode) {                    // 安卓三选开关
    case AndroidMode.tv:    return DeviceProfile.tv;
    case AndroidMode.phone: return DeviceProfile.mobile;
    case AndroidMode.auto:
      final isTv = MediaQuery.of(s.context).navigationMode ==
                   NavigationMode.directional          // 方向键导航 → TV
                || !s.hasTouchScreen;
      return isTv ? DeviceProfile.tv : DeviceProfile.mobile;
  }
}
```

```dart
// 显示入口（MaterialApp.builder）
builder: (context, child) {
  final profile = resolveProfile(settings);
  final scale = settings.fontScale;                 // 0.85–1.30
  return MediaQuery(
    data: mq.copyWith(textScaler: TextScaler.linear(scale)),
    child: DensityScope(profile: profile, scale: scale, child: child!),
  );
}
```

```dart
// 组件取值（唯一合法方式）
final t = AppTypography.of(context);   // 内部 = 三档表[profile]
final d = AppDensity.of(context);
Text(ch.name, style: TextStyle(fontSize: t.title));
SizedBox(width: d.buttonSize * scaleFor(context));  // 带标签按钮乘滑块
```

## 2.5 替换迁移步骤（全局还债清单）

1. 建 token 文件 + DensityScope（半天）
2. **全局搜索以下字面量并替换**（顺序：底部面板 → 频道列表 → EPG → 退出卡片 → OSD → 设置页）：
   - `fontSize: 数字`
   - 固定 `SizedBox(width/height: 数字)`（间距类）
   - `EdgeInsets.symmetric(horizontal: 数字)`（面板内边距）
   - 按钮 `width/height` / `IconButton` 默认尺寸
3. OSD 组件核对：频道号/台名/辅助行三槽全部走 token
4. 接入滑块：设置页 Slider(0.85–1.30, step 0.05) + "恢复默认" + 实时预览；确认**行高与带字按钮随动**（最大翻车点）
5. 安卓加设备模式三选项（Windows 不显示）
6. 删除各组件内残留的平台判断字号（如 `isTV ? 18 : 14` 散写）——统一收进三档表

## 2.6 验收清单

- [ ] 三端截图对比：同语义元素字号/尺寸符合数值表
- [ ] 手机横屏：面板 ≤ 屏高 1/6；频道列表一屏 ≥10 行
- [ ] 滑块 0.85 / 1.15 / 1.30 三档下：无文字溢出、无按钮截断、OSD 正常
- [ ] 安卓模式切"电视"后：整体切电视档、小窗功能消失；切回恢复
- [ ] 全局搜索 `fontSize:` 无业务组件命中（只剩 token 文件内）

---

# 两模块的依赖关系与总顺序

```
第 0 步 token 文件 + DensityScope          ← 模块二地基
第 1 步 焦点协调器 + player 分支           ← 模块一地基
第 2 步 token 全量替换（借协调器改面板时顺手做）
第 3 步 ghost 按钮组件（消费 token）
第 4-8 步 面板重排 / 防抖 / 哨兵 / 投屏态 / 快捷键
```

> 关键耦合点：面板重排（第 4 步）同时动"焦点接入"和"token 替换"，所以两模块地基必须先行，之后每个面板一次改到位（焦点进协调器 + 尺寸进 token），不二次返工。
