import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/app_colors.dart';
import '../services/player_controller.dart';
import 'time_pick_dialog.dart';

/// 定时关闭弹窗是否打开：播放页的全局按键处理据此放行。
/// 不放行的话，弹窗一打开方向键就被吞、OK 还会直接把弹窗关掉，
/// 遥控器用户根本进不到「设置…」里去选时间。
bool sleepTimerDialogOpen = false;

/// 定时关闭设置弹窗（底部面板与设置面板共用一套 UI）。
///
/// 三段：
/// 1. 到点动作：暂停播放 / 退出应用 / 退出并关机（桌面端独有）
/// 2. 倒计时：30 / 60 / 90 / 120 分钟
/// 3. 固定时刻：显示一个时刻（默认 23:30）+「设置」，点开遥控器友好的
///    时间选择器（上下调数值，见 time_pick_dialog.dart）
///
/// 所有 chip 都能被遥控器聚焦（FocusableActionDetector + ActivateIntent），
/// 上下移动焦点、OK 触发。
Future<void> showSleepTimerDialog(BuildContext context) async {
  final c = context.read<PlayerController>();
  final remain = c.sleepRemain;
  final setAt = c.sleepAt;
  var action = c.sleepAction;
  // 移动端没有关机语义，界面也不显示；历史值兜底成退出
  if (action == SleepAction.shutdown && !c.isDesktop) {
    action = SleepAction.exit;
  }

  Widget chip(String label, bool on, VoidCallback onTap,
      {bool autofocus = false}) {
    return Padding(
      padding: const EdgeInsets.only(right: 6, bottom: 6),
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        autofocus: autofocus,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              onTap();
              return null;
            },
          ),
        },
        child: Builder(builder: (inner) {
          // Focus.of 建立依赖：焦点进出时重建，边框随之变化
          final focused = Focus.of(inner).hasFocus;
          return InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              decoration: BoxDecoration(
                color: on
                    ? AppColors.accent.withValues(alpha: 0.18)
                    : Colors.transparent,
                border: Border.all(
                  color: focused
                      ? Colors.white
                      : (on ? AppColors.accent : AppColors.stroke),
                  width: focused ? 2 : 1,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(label,
                  style: TextStyle(
                      color: on ? AppColors.accent : AppColors.textPrimary,
                      fontSize: 13)),
            ),
          );
        }),
      ),
    );
  }

  sleepTimerDialogOpen = true;
  _SleepPick? picked;
  try {
    picked = await showDialog<_SleepPick>(
      context: context,
      barrierColor: AppColors.scrim,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: AppColors.overlay,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: AppColors.stroke),
          ),
          title: const Text('定时关闭',
              style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
          content: SizedBox(
            width: 320,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    remain == null
                        ? '到点自动执行下方动作'
                        : '${setAt == null ? '剩余' : '${_hhmm(setAt)} 关闭 · 剩余'}'
                            ' ${_fmtRemain(remain)}',
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 12.5),
                  ),
                  const SizedBox(height: 12),
                  const Text('到点做什么',
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 11.5)),
                  const SizedBox(height: 6),
                  Wrap(children: [
                    chip('暂停播放', action == SleepAction.pause,
                        () => setLocal(() => action = SleepAction.pause),
                        autofocus: true),
                    chip('退出应用', action == SleepAction.exit,
                        () => setLocal(() => action = SleepAction.exit)),
                    if (c.isDesktop)
                      chip('退出并关机', action == SleepAction.shutdown,
                          () => setLocal(() => action = SleepAction.shutdown)),
                  ]),
                  const SizedBox(height: 10),
                  const Text('倒计时',
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 11.5)),
                  const SizedBox(height: 6),
                  Wrap(children: [
                    for (final m in const [30, 60, 90, 120])
                      chip('$m 分钟', false, () {
                        Navigator.pop(
                            ctx,
                            _SleepPick(DateTime.now().add(Duration(minutes: m)),
                                action));
                      }),
                  ]),
                  const SizedBox(height: 10),
                  const Text('固定时刻（点「设置」选几点，今天已过算明天）',
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 11.5)),
                  const SizedBox(height: 6),
                  Row(children: [
                    Text(setAt != null ? _hhmm(setAt) : '23:30',
                        style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(width: 12),
                    chip('设置…', false, () async {
                      // 自绘时间选择器：系统表盘在遥控器上既不能拖也不能输入
                      final t = await showRemoteTimePicker(
                        ctx,
                        initial: setAt != null
                            ? TimeOfDay(hour: setAt.hour, minute: setAt.minute)
                            : const TimeOfDay(hour: 23, minute: 30),
                        title: '定时关闭时间',
                      );
                      if (t == null || !ctx.mounted) return;
                      Navigator.pop(
                          ctx, _SleepPick(_nextAt(t.hour, t.minute), action));
                    }),
                  ]),
                  if (remain != null || setAt != null) ...[
                    const SizedBox(height: 6),
                    TextButton.icon(
                      onPressed: () =>
                          Navigator.pop(ctx, _SleepPick(null, action)),
                      icon: const Icon(Icons.close, size: 16),
                      label: const Text('取消定时'),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.live,
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 32),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  } finally {
    sleepTimerDialogOpen = false;
  }
  if (picked == null || !context.mounted) return;
  await c.setSleepAt(picked.at, action: picked.action);
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
