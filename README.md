# 欧米视听 · Omi

跨平台直播视听应用：**电视直播 / 网络电台 / DLNA 投屏接收**，一套 Flutter 代码覆盖 Android、Windows、Linux（Web 实验性）。

> 本项目由 OMPlayer（欧米直播）全面改造升级而来，产品更名为**欧米视听（Omi）**，
> 仓库为 [coollightxp/omi-av](https://github.com/coollightxp/omi-av)，从 v1.0.0 起按 SemVer 重新计版。

## 产品定位

| 模式 | 说明 |
|---|---|
| 电视 | 直播流播放（HLS/DASH 等），M3U/TXT 源管理、EPG 节目单、节目预约 |
| 电台 | 网络电台播放，双域选台（电视/电台独立列表，遥控器一键切域） |
| 投屏 | DLNA Renderer，启动即待投，断开后自动恢复之前的播放状态 |
| WebView 直连 | 站点网页内嵌播放，嗅探到的直播流自动并入线路列表 |

## 功能特性

- 📺 **直播播放**：HLS/DASH 直播流，源选择器 `‹2/6›` 尖括号步进器
- 📋 **播放列表管理**：M3U / TXT 格式，URL 或本地文件导入
- 📅 **EPG 节目单**：XMLTV 解析，多 EPG 源切换
- ⏰ **节目预约**：到点自动切台，预约记录持久化
- 🎬 **录制与截图**：桌面端录制/截图，保存到 `recordings` / `screenshots`
- 📡 **DLNA 投屏接收**：设备名 `欧米视听-机器标识`，断开自动恢复播放
- 🗂️ **两级抽屉**：左侧频道分类抽屉，右侧 EPG 面板
- 🎚️ **手势控制**：左侧上下滑调亮度，右侧上下滑调音量
- ⚙️ **系统设置**：开机启动、启动全屏、系统时钟、标题栏悬停呼出

## 架构说明（本次改造新增）

### 焦点协调器 FocusCoordinator
- `lib/core/focus/`：全 App **唯一的按键分发点**，基于 Region 栈（`player / channelDrawer / epgPanel / settingsPanel / sourceDialog …`）
- 解决多面板堆叠时的**焦点穿透**问题：只有栈顶 Region 处理按键；KeyUp 同样转发给栈顶，保证 OK/左右键短按-长按配对
- `safe_focus.dart` 提供 `safeRequestFocus`（postFrame 后聚焦），避免对未挂载节点请求焦点导致的异常

### 密度 / 字号 Token 体系
- `lib/core/theme/`：
  - `device_profile.dart` — 设备档自动判定（手机 / 电视 / 桌面）
  - `app_density.dart` — 三档尺寸 token（面板高、按钮、间距等）
  - `app_typography.dart` — 三档字号 token（含 OSD 专用槽）
  - 安卓提供「自动 / 手机 / 电视」设备模式开关，用户可在 0.85–1.30 滑块微调
- 所有面板、按钮、OSD 尺寸统一走 token，杜绝手写 magic number

### 统一视觉
- `lib/core/theme/app_colors.dart` — 四级表面体系（surface / overlay / stroke / scrim），暗画面下面板边界可辨
- `lib/core/widgets/ghost_button.dart` — 统一按钮：TV 焦点发光、无水波纹、尺寸走 token

### 版本与发布纪律（SemVer）
- **git tag 是版本号的唯一来源**，禁止手改 pubspec 版本号（历史教训：补丁号被刷到 100+）
- 三级流水线：`push → beta.N` / `rc tag → Pre-release` / `正式 tag → Release`
- CI（`.github/workflows/build.yml`）现场 `flutter create` 生成平台目录，注入原生组件：
  - Android：`OmiLocalFilePickerPlugin.kt`（SAF 受限场景的全格式本地文件选择）
  - Windows：单实例互斥锁、NumLock 一次性恢复、低级键盘钩子（`omi/win_hotkeys` 通道）、WebView2 缓存清理与自动播放授权

### 命名与兼容性说明
- 应用名 / 界面标题 / DLNA 设备名 / 自启动项：**欧米视听 / Omi**
- MethodChannel 通道名：`omi/local_file_picker`、`omi/win_hotkeys`（Dart 与 CI 注入的原生侧已同步改名）
- **SharedPreferences 存储键保留 `omplayer_` 前缀**（`omplayer_playlists`、`omplayer_reservations` 等）：
  这是刻意为之，保证老用户升级后播放列表、预约、收藏、EPG 配置**不丢失**

## 平台支持

| 平台 | 支持状态 |
|---|---|
| Android | ✅ 手机 / 电视盒（遥控器按键完整适配） |
| Windows | ✅ Win10 1607+（WebView 直连在 1607 上自动禁用并回退直连流） |
| Linux | ✅ |
| Web | 🧪 实验性 |

## 开发

```bash
flutter pub get
flutter run -d <device>
```

设计文档见 [`docs/`](docs/)：

- `欧米直播改造方案.md` — 总体方案（设计哲学、架构、面板、按键矩阵、双域选台、电台、版本规范）
- `改造方案-实施细则.md` — 分步实施细节与验收标准
- `重点模块详设-焦点协调器与密度Token.md` — 两大基础模块详设

## 版本历史

| 版本 | 说明 |
|---|---|
| v1.0.0 起 | 欧米视听（Omi），品牌与架构全面升级 |
| （前身） | OMPlayer 1.1.006 及更早 |
