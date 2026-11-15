# AI 工作备忘（会话摘要 · 随工作进度更新）

> 用途：对话会被压缩，本文档是**唯一可靠的记忆载体**。凡涉及「改过什么、为什么改、验证没有」，以本文档和《版本台账-基线重建.md》为准，不凭印象。每轮工作收尾时更新本文件。
> 记录格式：每笔工作一条，含【发现 / 改动 / 位置 / 验证状态】。

## 一、项目关键信息

| 项 | 值 |
|---|---|
| 本地工作区 | `/tmp/v213proj`（主）；`/tmp/v2137/` 是 2.1.37 基线四文件（player_screen / player_controller / win_hotkeys / build.yml），**对账唯一基准** |
| 仓库 | coollightxp/omi-av；推送脚本 `/tmp/push_v225.py`（由 v223 演化）；PAT 在 `/tmp/omi_pat` |
| CI | push main → Actions 出测试 artifact；打 tag → 正式 Release。三路：win / android-arm / android-x64 |
| 版本演进 | 2.1.37（用户验证：网页/遥控器零问题，定时卡片、logo 均已在此版）→ 2.2.0 托盘改版 → 2.2.1 输入法误诊期（猜测改动，已全退）→ 2.2.3 vk兜底+热区（未验证，已退）→ 2.2.4 状态机回退 → 2.2.5 网页通路整体回退 |

## 二、核心纪律（用户反复强调）

1. **不猜**：涉及版本/改动先查台账、git 历史、基线 diff；查不到就说查不到。
2. **不对比基线不改码**：每次改动先与 2.1.37 diff 对应区域，逐行说清「改什么、为什么、对应哪个取证结论」。
3. **一次只动一个变量**：改完出测试包 → 用户验证 → 通过才进下一项。
4. **Windows 已验证逻辑冻结**：win_hotkeys、钩子段、windows 分支，修安卓不碰。
5. **平台分层**：UI/业务通用；系统级各平台各写（`xxx + _io + _stub` 三件套），接口对齐 `_onNativeAction`。
6. **安卓另起一条路**：不套 Windows 补丁；先取证（WebDiag + 真机日志）再修码。

## 三、工作记录（倒序，最新在上）

### 记录 #6 · 2026-11-15 · v2.2.5 网页遥控通路整体回退
- 【发现】2.2.4 状态机已复原但用户实测症状复现 → 元凶在网页通路其余改动。基线取证：`g_om_web_forward` 在 2.1.37 钩子里是**死变量**（只声明未使用）。
- 【改动】build.yml 钩子：删 VK_SELECT/0xC3 映射、fg_ok 恢复 `OMForegroundIsOurs()`、删未知 VK 上报块（保留 F9/X1X0 最小支持）。player_screen：删 vk 兜底分支与 `_vkSynth`、`_onWebKey` 恢复原版、JS Esc 恢复只发 exitfullscreen、边缘热区恢复 20px/仅 onEnter/无 child。
- 【位置】`.github/workflows/build.yml` 钩子段、`player_screen.dart` ~445/855/3776 行附近。
- 【验证】flutter analyze 无 error；构建 run `43687016735`；**待用户真机测试**。

### 记录 #5 · 2026-11-15 · v2.2.4 按键状态机回退 2.1.37
- 【改动】删时间戳自愈全套（`_okHeldAt/_arrowDownAt/_menuHeldAt/_nativeHeldAt`）；`_nativeHeld` 恢复 Set+add()；ok/lr/menu 键函数逐字复原；`_verticalKey` 面板分支复原；修复 part1 漏改点 `_resetKeyPairing` 里 `_nativeHeldAt.clear()`→`_nativeHeld.clear()`。
- 【验证】逐函数 md5 与基线比对一致；构建成功；用户实测**症状仍复现**（由此引出 #6）。

### 记录 #4 · 2026-11-15 · v2.2.3（已作废回退）
- 【改动】vk 兜底、fg_ok 放宽、热区 32px+onHover+child——**未验证且被证伪**，见 #6。

### 记录 #3 · 用户明确的取舍
- 定时卡片、绿色小精灵 logo 在 2.1.37 已有且正常，非 2.2.x 新增。
- 保留项仅：摸鱼（F9）、托盘两项、静音键修复、tag 发布流程。

### 记录 #2 · 安卓线（未开工）
- 症状与 Windows「面板关联」同源；机制差异：安卓网页用 flutter_inappwebview、无钩子通道、软键盘走 IME 不进 HardwareKeyboard、CI 工程零自定义 Kotlin。
- 分析文档：`docs/安卓按键通路与面板关联-机制分析.md`。
- **开线前置核查**：① 安卓 13+ 通知权限申请流程在 2.1.37 后被简化（基线有 notifResult 异步挂起+渠道重要性检查，现状是 fire-and-forget）——需确认是否恢复；② 新增「遥控器焦点高亮」（android.view.View）——确认去留。
- 流程：先补 WebDiag 盲区埋点（HardwareKeyboard 收键 / PopScope / 面板状态迁移）→ 用户真机取证 → 最小修复。

### 记录 #1 · 根因定性（Windows 侧，已闭环）
- 网页态遥控失灵根因 = **面板/全屏状态与按键通路的关联**（设置面板打开时按键被面板消费，关闭后通路/状态位未正确归还）。
- 输入法误诊期（2.2.1）加的时间戳自愈等全部猜测改动已在 2.2.4/2.2.5 退光。
