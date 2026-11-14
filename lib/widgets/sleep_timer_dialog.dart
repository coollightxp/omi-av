import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/theme/app_colors.dart';
import '../services/player_controller.dart';
import 'time_pick_dialog.dart';

/// 定时关闭弹窗是否打开：播放页的全局按键处理据此放行。
/// 不放行的话，弹窗一打开方向键就被吞、OK 还会直接把弹窗关掉，
/// 遥控器用户根本进不到「设置…」里去选时间。
bool sleepTimerDialogOpen = false;

/// 定时关闭设置弹窗（退出卡片上的「定时关闭」入口）。
///
/// 三段：
/// 1. 到点动作：暂停播放 / 退出应用 / 退出并关机（桌面端独有）
/// 2. 倒计时：30 / 60 / 90 / 120 分钟
/// 3. 固定时刻：显示一个时刻（默认 23:30）+「设置」，点开遥控器友好的
///    时间选择器（上下调数值，见 time_pick_dialog.dart）
///
/// 遥控器导航（用户实测定稿的「三趟」模型）：
/// - **上下** = 在三趟之间**循环**走（动作 → 倒计时 → 固定时刻）
/// - **左右** = 同一趟内循环换项；动作这一趟「左右即改选中」，OK 确认
/// - **OK** = 倒计时这一趟直接生效并关闭；固定时刻进时间选择器，
///   确定后同样关闭；动作这一趟只是确认，不关闭
/// - **返回/Esc** = 关掉不保存
Future<void> showSleepTimerDialog(BuildContext context) async {
  final c = context.read<PlayerController>();
  var action = c.sleepAction;
  // 移动端没有关机语义，界面也不显示；历史值兜底成退出
  if (action == SleepAction.shutdown && !c.isDesktop) {
    action = SleepAction.exit;
  }

  sleepTimerDialogOpen = true;
  _SleepPick? picked;
  try {
    picked = await showDialog<_SleepPick>(
      context: context,
      barrierColor: AppColors.scrim,
      builder: (_) => _SleepTimerDialog(
        initialAction: action,
        remain: c.sleepRemain,
        setAt: c.sleepAt,
        showShutdown: c.isDesktop,
      ),
    );
  } finally {
    sleepTimerDialogOpen = false;
  }
  if (picked == null || !context.mounted) return;
  await c.setSleepAt(picked.at, action: picked.action);
}

class _SleepTimerDialog extends StatefulWidget {
  const _SleepTimerDialog({
    required this.initialAction,
    required this.remain,
    required this.setAt,
    required this.showShutdown,
  });

  final SleepAction initialAction;
  final Duration? remain;
  final DateTime? setAt;
  final bool showShutdown;

  @override
  State<_SleepTimerDialog> createState() => _SleepTimerDialogState();
}

class _SleepTimerDialogState extends State<_SleepTimerDialog> {
  late SleepAction _action = widget.initialAction;

  /// 每个选项的焦点节点：按 id 复用，不能每次 build 新建
  final Map<String, FocusNode> _nodes = {};

  /// 每行的焦点节点顺序（build 时重建）：上下换行、左右换列都靠它
  final List<List<FocusNode>> _rows = [];
  final Map<FocusNode, VoidCallback> _tap = {};

  int _row = 0;
  int _col = 0;
  bool _focusedOnce = false;

  /// 按键去重：HardwareKeyboard 与焦点树两条通道都挂（见 _consume），
  /// 同一颗键 60ms 内的第二次派发直接吞掉，避免"按一下走两格"
  int _lastKeyId = 0;
  int _lastKeyAt = 0;

  FocusNode _node(String id) => _nodes.putIfAbsent(id, () {
        final n = FocusNode(debugLabel: 'sleep:$id');
        // 只注册一次：焦点落到哪就把行/列记下来（鼠标点击也会同步，
        // 之后方向键从当前位置接着走）。在 _chip 里挂会每次 build 重复加
        n.addListener(() {
          if (!mounted) return;
          if (n.hasFocus) _syncPos(n);
        });
        return n;
      });

  @override
  void initState() {
    super.initState();
    // 遥控器按键走 HardwareKeyboard 通道（与在线电台弹窗同一通道）。
    // 之前挂在 Focus.onKeyEvent 上，用户实测弹窗里遥控器完全没反应——
    // 通道问题不在本弹窗的逻辑，而在按键根本没被派发进这条弹窗的
    // 焦点链。硬件键盘通道已被设置页/电台弹窗证明在这台机器上可靠。
    HardwareKeyboard.instance.addHandler(_consume);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_consume);
    for (final n in _nodes.values) {
      n.dispose();
    }
    super.dispose();
  }

  /// 登记一个选项：同一行内按加入顺序排列
  void _register(int row, String id, VoidCallback onTap) {
    while (_rows.length <= row) {
      _rows.add(<FocusNode>[]);
    }
    final node = _node(id);
    _tap[node] = onTap;
    _rows[row].add(node);
  }

  FocusNode? get _current {
    if (_row < 0 || _row >= _rows.length) return null;
    final list = _rows[_row];
    if (list.isEmpty) return null;
    return list[_col.clamp(0, list.length - 1)];
  }

  /// 焦点跑到哪，就把行/列记下来（鼠标点击也会同步，方向键接着走）
  void _syncPos(FocusNode n) {
    for (var r = 0; r < _rows.length; r++) {
      final c = _rows[r].indexOf(n);
      if (c >= 0) {
        _row = r;
        _col = c;
        return;
      }
    }
  }

  void _move(int dRow, int dCol) {
    if (_rows.isEmpty) return;
    if (dRow != 0) {
      // 三趟之间**循环**：最后一趟再按下回到第一趟，第一趟按上回到最后
      // （与设置页/搜索弹窗同一套心智，用户要求「上下循环选这三趟」）
      final n = _rows.length;
      var r = (_row + dRow) % n;
      if (r < 0) r += n;
      var list = _rows[r];
      // 跳过空行（例如没有「取消定时」这一趟时不该停住）
      var guard = 0;
      while (list.isEmpty && guard++ < n) {
        r = (r + dRow) % n;
        if (r < 0) r += n;
        list = _rows[r];
      }
      if (list.isEmpty) return;
      _row = r;
      _col = _col.clamp(0, list.length - 1);
      list[_col].requestFocus();
      return;
    }
    final list = _rows[_row];
    if (list.isEmpty) return;
    // 同一趟内左右也循环：最后一格再按右回到第一格
    final n = list.length;
    var c = (_col + dCol) % n;
    if (c < 0) c += n;
    _col = c;
    list[_col].requestFocus();
    // 动作这一趟（第 0 趟）是「左右键直接调整选中项」，不是先移焦点
    // 再按 OK——用户明确要求：左右调，OK 确认
    if (_row == 0) _tap[list[_col]]?.call();
  }

  void _activate() {
    final n = _current;
    if (n == null) return;
    _tap[n]?.call();
  }

  /// 遥控器/键盘按键：HardwareKeyboard 与焦点树两条通道都进这里。
  ///
  /// 用户这台机器上遥控器键有时进硬件通道、有时只走焦点链，单挂一条就
  /// 会出现"整个卡片按不动"。两条都挂 + 60ms 同键去重，哪条先到都只
  /// 执行一次。必须自己是栈顶弹窗才动手——从这里再打开时间选择器时，
  /// 按键归它，不能两层一起动。
  bool _consume(KeyEvent event) {
    if (!mounted) return false;
    // 从这里打开的时间选择器在上层：按键归它，本层不跟着动
    if (remoteTimePickerOpen) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    final k = event.logicalKey;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (k.keyId == _lastKeyId && now - _lastKeyAt < 60) return true;
    _lastKeyId = k.keyId;
    _lastKeyAt = now;
    if (k == LogicalKeyboardKey.arrowUp) {
      _move(-1, 0);
      return true;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      _move(1, 0);
      return true;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      _move(0, -1);
      return true;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      _move(0, 1);
      return true;
    }
    if (k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.gameButtonA ||
        k == LogicalKeyboardKey.space) {
      if (event is KeyDownEvent) _activate();
      return true;
    }
    if (k == LogicalKeyboardKey.escape ||
        k == LogicalKeyboardKey.goBack ||
        k == LogicalKeyboardKey.browserBack ||
        k == LogicalKeyboardKey.contextMenu) {
      if (event is KeyDownEvent) Navigator.pop(context);
      return true;
    }
    return false;
  }

  Widget _chip(int row, String id, String label, bool on, VoidCallback onTap) {
    _register(row, id, onTap);
    final node = _node(id);
    return _SleepChip(node: node, label: label, selected: on, onTap: onTap);
  }

  @override
  Widget build(BuildContext context) {
    _rows.clear();
    _tap.clear();

    final remain = widget.remain;
    final setAt = widget.setAt;

    final actionChips = <Widget>[
      _chip(0, 'act:pause', '暂停播放', _action == SleepAction.pause,
          () => setState(() => _action = SleepAction.pause)),
      _chip(0, 'act:exit', '退出应用', _action == SleepAction.exit,
          () => setState(() => _action = SleepAction.exit)),
      if (widget.showShutdown)
        _chip(0, 'act:shutdown', '退出并关机', _action == SleepAction.shutdown,
            () => setState(() => _action = SleepAction.shutdown)),
    ];
    final timerChips = <Widget>[
      for (final m in const [30, 60, 90, 120])
        _chip(1, 'min:$m', '$m 分钟', false, () {
          Navigator.pop(context,
              _SleepPick(DateTime.now().add(Duration(minutes: m)), _action));
        }),
    ];
    final atChips = <Widget>[
      _chip(2, 'at:set', '设置…', false, () async {
        final t = await showRemoteTimePicker(
          context,
          initial: setAt != null
              ? TimeOfDay(hour: setAt.hour, minute: setAt.minute)
              : const TimeOfDay(hour: 23, minute: 30),
          title: '定时关闭时间',
        );
        if (t == null || !mounted) return;
        Navigator.pop(context, _SleepPick(_nextAt(t.hour, t.minute), _action));
      }),
    ];

    // 首次进入把焦点放到第一个选项上，遥控器一打开就能按
    if (!_focusedOnce && _rows.isNotEmpty && _rows.first.isNotEmpty) {
      _focusedOnce = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _rows.isNotEmpty && _rows.first.isNotEmpty) {
          _rows.first.first.requestFocus();
        }
      });
    }

    return Focus(
      // 双保险：硬件通道收不到时，按键沿焦点链冒泡到这里
      autofocus: true,
      onKeyEvent: (_, e) => _consume(e)
          ? KeyEventResult.handled
          : KeyEventResult.ignored,
      child: AlertDialog(
      backgroundColor: AppColors.overlay,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.stroke),
      ),
      title: const Text('定时关闭',
          style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
      content: SizedBox(
        width: 340,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (remain != null)
                Text(
                  '${setAt == null ? '剩余' : '${_hhmm(setAt)} 关闭 · 剩余'}'
                  ' ${_fmtRemain(remain)}',
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 12.5),
                ),
              // 「到点自动执行下方动作」「到点做什么」都是废话（2026-11-14
              // 用户实测点名去掉）；各段之间行距也一并收紧
              const SizedBox(height: 10),
              Wrap(spacing: 6, runSpacing: 5, children: actionChips),
              // 三趟之间留出明显段落：以前标签贴着上一排 chip，看着像
              // 同一组；用户要求「倒计时 / 23:30 那行 / 底部说明」都拉开
              const SizedBox(height: 16),
              const _SectionLabel('倒计时'),
              const SizedBox(height: 7),
              Wrap(spacing: 6, runSpacing: 5, children: timerChips),
              const SizedBox(height: 16),
              const _SectionLabel('固定时刻（点「设置」选几点，今天已过算明天）'),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(setAt != null ? _hhmm(setAt) : '23:30',
                      style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(width: 12),
                  ...atChips,
                ],
              ),
              if (remain != null || setAt != null) ...[
                const SizedBox(height: 10),
                _chip(3, 'cancel', '取消定时', false,
                    () => Navigator.pop(context, _SleepPick(null, _action))),
              ],
              const SizedBox(height: 14),
              const Text('上下换一行 · 左右换一项 · OK 确定 · 返回退出',
                  style:
                      TextStyle(color: AppColors.textTertiary, fontSize: 11)),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(color: AppColors.textSecondary, fontSize: 11.5));
}

/// 可聚焦的选项方块：焦点在时白框，选中态用主色
class _SleepChip extends StatelessWidget {
  const _SleepChip({
    required this.node,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final FocusNode node;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: node,
      child: Builder(builder: (inner) {
        // Focus.of 建立依赖：焦点进出时重建，描边随之变化
        final focused = Focus.of(inner).hasFocus;
        return GestureDetector(
          onTap: () {
            node.requestFocus();
            onTap();
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              decoration: BoxDecoration(
                color: selected
                    ? AppColors.accent.withValues(alpha: 0.18)
                    : Colors.transparent,
                border: Border.all(
                  color: focused
                      ? Colors.white
                      : (selected ? AppColors.accent : AppColors.stroke),
                  width: focused ? 2 : 1,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(label,
                  style: TextStyle(
                      color:
                          selected ? AppColors.accent : AppColors.textPrimary,
                      fontSize: 13)),
            ),
          ),
        );
      }),
    );
  }
}

/// 今天/明天最近的那个 HH:mm（凌晨选 23:30 就是明晚）
DateTime _nextAt(int hour, int minute) {
  final now = DateTime.now();
  var t = DateTime(now.year, now.month, now.day, hour, minute);
  if (!t.isAfter(now)) t = t.add(const Duration(days: 1));
  return t;
}

String _hhmm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String _fmtRemain(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final sec = d.inSeconds % 60;
  if (h > 0) {
    return '$h:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }
  return '$m:${sec.toString().padLeft(2, '0')}';
}

/// 弹窗选择结果：[at] 为 null 表示取消定时。
class _SleepPick {
  const _SleepPick(this.at, this.action);

  final DateTime? at;
  final SleepAction action;
}
