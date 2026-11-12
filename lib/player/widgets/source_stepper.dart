import 'package:flutter/material.dart';

import '../../core/theme/app_density.dart';
import '../../core/theme/app_typography.dart';
import '../../core/widgets/ghost_button.dart';

/// 换源步进器：`‹  线路 2/6 ▾  ›`
///
/// - 左右箭头走上一源/下一源（与遥控器 ←/→ 同一路径）
/// - 点击中间文字弹出线路列表，可直接跳选（含当前项打勾）
/// - 遥控器高亮态由 [prevSelected]/[nextSelected] 传入，样式与面板其它按钮一致
///
/// 网页频道前台时（[qualityLabel] 非空）不弹菜单：此时左右键映射为
/// 清晰度循环，菜单无意义。
class SourceStepper extends StatelessWidget {
  const SourceStepper({
    super.key,
    required this.index,
    required this.count,
    required this.onPrev,
    required this.onNext,
    this.onSelect,
    this.qualityLabel,
    this.prevSelected = false,
    this.nextSelected = false,
  });

  /// 当前源下标（0 起）
  final int index;

  /// 源总数
  final int count;

  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  /// 直接跳选第 i 个源（i 从 0 起）
  final ValueChanged<int>? onSelect;

  /// 网页清晰度文案（非空时替代"线路 n/m"显示，且不弹菜单）
  final String? qualityLabel;

  final bool prevSelected;
  final bool nextSelected;

  bool get _isWeb => qualityLabel != null;

  @override
  Widget build(BuildContext context) {
    final d = AppDensity.of(context);
    final t = AppTypography.of(context);
    final label = _isWeb ? qualityLabel! : '线路 ${index + 1}/$count';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _arrow(
          context,
          icon: Icons.chevron_left,
          tooltip: _isWeb ? '降低清晰度' : '上一个源',
          onTap: onPrev,
          selected: prevSelected,
        ),
        // 中央标签：可点击弹出线路菜单
        InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: (!_isWeb && count > 1 && onSelect != null)
                ? () => _showMenu(context, d, t)
                : null,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: d.intraGroupGap * 0.4,
                vertical: 6,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: t.caption,
                    ),
                  ),
                  if (!_isWeb && count > 1 && onSelect != null)
                    Icon(Icons.arrow_drop_down,
                        size: t.caption + 6, color: Colors.white54),
                ],
              ),
          ),
        ),
        _arrow(
          context,
          icon: Icons.chevron_right,
          tooltip: _isWeb ? '提升清晰度' : '下一个源',
          onTap: onNext,
          selected: nextSelected,
        ),
      ],
    );
  }

  Widget _arrow(
    BuildContext context, {
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
    required bool selected,
  }) {
    // 与面板其它按钮同一组件：高亮态永远是白描边，
    // 不再出现"箭头是蓝框、其它钮是白框"的混搭
    return GhostButton(
      icon: icon,
      tooltip: tooltip,
      onPressed: onTap,
      selected: selected,
    );
  }

  /// 线路菜单：在标签上方弹出，当前项打勾
  Future<void> _showMenu(
      BuildContext context, AppDensity d, AppTypography t) async {
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    final width = box.size.width.clamp(160.0, 240.0);
    final chosen = await showMenu<int>(
      context: context,
      position: RelativeRect.fromLTRB(
        origin.dx,
        origin.dy - (count * (d.listRowHeight * 0.8) + 16),
        overlay.size.width - origin.dx - width,
        0,
      ),
      color: const Color(0xF01A1614),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(d.modalRadius),
      ),
      items: [
        for (var i = 0; i < count; i++)
          PopupMenuItem<int>(
            value: i,
            height: d.listRowHeight * 0.8,
            child: Row(
              children: [
                SizedBox(
                  width: 22,
                  child: i == index
                      ? const Icon(Icons.check,
                          size: 16, color: Color(0xFFFFB35C))
                      : null,
                ),
                Text(
                  '线路 ${i + 1}',
                  style: TextStyle(
                    color: i == index ? Colors.white : Colors.white70,
                    fontSize: t.body,
                  ),
                ),
                const Spacer(),
                if (i == index)
                  Text('当前',
                      style:
                          TextStyle(color: Colors.white38, fontSize: t.caption)),
              ],
            ),
          ),
      ],
    );
    if (chosen != null && chosen != index) onSelect?.call(chosen);
  }
}
