import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/app_colors.dart';
import '../services/player_controller.dart';

/// 定时关闭设置弹窗（底部面板与设置面板共用一套 UI）。
///
/// 三段：
/// 1. 到点动作：暂停播放 / 退出应用 / 退出并关机（桌面端独有）
/// 2. 倒计时：30 / 60 / 90 / 120 分钟
/// 3. 固定时刻：22:00 ~ 00:00 常用档 + 自定义（最近一次，过了就顺延到明天）
Future<void> showSleepTimerDialog(BuildContext context) async {
  final c = context.read<PlayerController>();
  final remain = c.sleepRemain;
  final setAt = c.sleepAt;
  var action = c.sleepAction;
  // 移动端没有关机语义，界面也不显示；历史值兜底成退出
  if (action == SleepAction.shutdown && !c.isDesktop) {
    action = SleepAction.exit;
  }

  Widget chip(String label, bool on, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 6, bottom: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            color:
                on ? AppColors.accent.withValues(alpha: 0.18) : Colors.transparent,
            border:
                Border.all(color: on ? AppColors.accent : AppColors.stroke),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(label,
              style: TextStyle(
                  color: on ? AppColors.accent : AppColors.textPrimary,
                  fontSize: 13)),
        ),
      ),
    );
  }

  final picked = await showDialog<_SleepPick>(
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
                      () => setLocal(() => action = SleepAction.pause)),
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
                          _SleepPick(
                              DateTime.now().add(Duration(minutes: m)), action));
                    }),
                ]),
                const SizedBox(height: 10),
                const Text('固定时刻（最近一次）',
                    style: TextStyle(
                        color: AppColors.textSecondary, fontSize: 11.5)),
                const SizedBox(height: 6),
                Wrap(children: [
                  for (final hm in const [
                    [22, 0],
                    [22, 30],
                    [23, 0],
                    [23, 30],
                    [0, 0],
                  ])
                    chip(
                      '${hm[0].toString().padLeft(2, '0')}:'
                      '${hm[1].toString().padLeft(2, '0')}',
                      false,
                      () => Navigator.pop(ctx, _SleepPick(_nextAt(hm[0], hm[1]), action)),
                    ),
                  chip('自定义…', false, () async {
                    final now = DateTime.now();
                    final t = await showTimePicker(
                      context: ctx,
                      initialTime:
                          TimeOfDay(hour: now.hour, minute: now.minute),
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
