import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// 待机壳：投屏等待 / 待选台共用的一套"深色极简待机画面"。
///
/// 方案 3.7 与第九节要求两者同壳——一个图标 + 两行字，不出现任何
/// 播放控件。区别只在文案与响应动作，所以文案全部由调用方传入。
class StandbyShell extends StatelessWidget {
  const StandbyShell({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.hint,
    this.topBadge,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  /// 底部常驻操作提示（如「双击返回键 返回直播」）
  final String? hint;

  /// 顶部小徽标（如「投屏」）
  final String? topBadge;

  @override
  Widget build(BuildContext context) {
    return Container(
      // 比纯黑略亮的深蓝灰，与面板同色系但不抢视线
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.15),
          radius: 1.1,
          colors: [Color(0xFF11161D), Color(0xFF05070A)],
        ),
      ),
      child: Stack(
        children: [
          if (topBadge != null)
            Positioned(
              top: 28,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.stroke),
                  ),
                  child: Text(
                    topBadge!,
                    style: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: 11.5,
                      letterSpacing: 2,
                    ),
                  ),
                ),
              ),
            ),
          Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 56, color: Colors.white24),
                    const SizedBox(height: 22),
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 21,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.2,
                      ),
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        subtitle!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 13.5,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (hint != null && hint!.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 34,
              child: Center(
                child: Text(
                  hint!,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.24),
                    fontSize: 12,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
