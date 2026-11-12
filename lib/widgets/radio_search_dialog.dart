import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/app_colors.dart';
import '../core/widgets/channel_badge.dart';
import '../core/widgets/ghost_button.dart';
import '../models/channel.dart';
import '../models/radio_station.dart';
import '../services/osd_bus.dart';
import '../services/player_controller.dart';
import '../services/radio_directory.dart';

/// 在线电台搜索（Radio Browser 目录）。
///
/// 设计原则（方案 12.2 第 3 条）：不新增"添加电台源"入口，
/// 而是给一个搜索入口——搜到哪台加哪台，加进「我的电台」。
/// 列表里已加的台直接显示勾选态，再点一次即移除。
class RadioSearchDialog extends StatefulWidget {
  const RadioSearchDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog(
        context: context,
        barrierColor: AppColors.scrim,
        builder: (_) => const RadioSearchDialog(),
      );

  @override
  State<RadioSearchDialog> createState() => _RadioSearchDialogState();
}

class _RadioSearchDialogState extends State<RadioSearchDialog> {
  final TextEditingController _queryCtl = TextEditingController();
  final FocusNode _queryFocus = FocusNode(debugLabel: 'radioSearchQuery');

  List<RadioStation> _results = const [];
  bool _loading = false;
  String _error = '';
  bool _cnOnly = true;
  String _tag = '';
  String _lastQuery = '';

  @override
  void initState() {
    super.initState();
    // 首屏给中国区热门，避免面对空白
    _search();
  }

  @override
  void dispose() {
    _queryCtl.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  Future<void> _search({String? tag}) async {
    if (_loading) return;
    final q = _queryCtl.text.trim();
    setState(() {
      _loading = true;
      _error = '';
      _tag = tag ?? _tag;
      _lastQuery = q;
    });
    try {
      final list = await RadioDirectory.search(
        query: q,
        tag: _tag,
        cnOnly: _cnOnly,
      );
      if (!mounted) return;
      setState(() {
        _results = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _results = const [];
        _loading = false;
      });
    }
  }

  Future<void> _toggle(RadioStation s) async {
    final c = context.read<PlayerController>();
    if (c.isStationSaved(s.id)) {
      await c.removeRadioStation(s.id);
      if (!mounted) return;
      OsdBus.show('已从我的电台移除：${s.name}', icon: Icons.remove_circle_outline);
    } else {
      await c.addRadioStation(s);
      if (!mounted) return;
      OsdBus.show('已加入我的电台：${s.name}', icon: Icons.playlist_add_check);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Container(
        width: size.width * 0.82,
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 640),
        decoration: BoxDecoration(
          color: AppColors.overlay,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.stroke),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _header(),
            const Divider(color: AppColors.divider, height: 1),
            _searchBar(),
            _tagBar(),
            const Divider(color: AppColors.divider, height: 1),
            Expanded(child: _resultArea()),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
      child: Row(
        children: [
          const Icon(Icons.travel_explore, color: AppColors.accent, size: 20),
          const SizedBox(width: 8),
          const Text(
            '在线电台',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '搜索后加入「我的电台」，与电视源共用同一个入口',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.textTertiary,
                fontSize: 12,
              ),
            ),
          ),
          GhostButton(
            icon: Icons.close,
            tooltip: '关闭',
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 44,
              child: TextField(
                controller: _queryCtl,
                focusNode: _queryFocus,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 14,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '电台名，如「中国之声」「上海交通」',
                  hintStyle: TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 13,
                  ),
                  prefixIcon: const Icon(Icons.search,
                      color: AppColors.textTertiary, size: 18),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.05),
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: AppColors.stroke),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: AppColors.stroke),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: AppColors.accent),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GhostButton(
            icon: Icons.search,
            tooltip: '搜索 (回车)',
            onPressed: _loading ? null : () => _search(),
          ),
          const SizedBox(width: 4),
          // 仅中国：默认开，搜"音乐"不会出来一堆国外台
          FilterChip(
            label: const Text('仅中国', style: TextStyle(fontSize: 12)),
            selected: _cnOnly,
            onSelected: (v) {
              setState(() => _cnOnly = v);
              _search();
            },
            selectedColor: AppColors.accent.withValues(alpha: 0.25),
            backgroundColor: Colors.white.withValues(alpha: 0.04),
            side: BorderSide(color: AppColors.stroke),
            checkmarkColor: AppColors.textPrimary,
            labelStyle: TextStyle(
              color: _cnOnly ? AppColors.textPrimary : AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tagBar() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Row(
        children: [
          for (final (label, tag) in RadioDirectory.quickTags) ...[
            if (tag != RadioDirectory.quickTags.first.$2)
              const SizedBox(width: 6),
            ChoiceChip(
              label: Text(label, style: const TextStyle(fontSize: 12)),
              selected: _tag == tag,
              onSelected: (_) {
                // 再点一次取消标签，回到普通搜索
                final next = _tag == tag ? '' : tag;
                _queryCtl.clear();
                _search(tag: next);
              },
              selectedColor: AppColors.accent.withValues(alpha: 0.25),
              backgroundColor: Colors.white.withValues(alpha: 0.04),
              side: BorderSide(color: AppColors.stroke),
              labelStyle: TextStyle(
                color: _tag == tag
                    ? AppColors.textPrimary
                    : AppColors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _resultArea() {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      );
    }
    if (_error.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off,
                  color: AppColors.textTertiary, size: 36),
              const SizedBox(height: 12),
              Text(
                _error,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => _search(),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_results.isEmpty) {
      return Center(
        child: Text(
          _lastQuery.isEmpty && _tag.isEmpty
              ? '目录暂时没有返回结果'
              : '没搜到「$_lastQuery」，换个关键词或取消「仅中国」试试',
          style: const TextStyle(
              color: AppColors.textTertiary, fontSize: 13),
        ),
      );
    }
    final controller = context.watch<PlayerController>();
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _results.length,
      separatorBuilder: (_, __) =>
          const Divider(color: AppColors.divider, height: 1),
      itemBuilder: (context, i) {
        final s = _results[i];
        final saved = controller.isStationSaved(s.id);
        return _StationRow(
          station: s,
          saved: saved,
          onToggle: () => _toggle(s),
        );
      },
    );
  }
}

class _StationRow extends StatelessWidget {
  const _StationRow({
    required this.station,
    required this.saved,
    required this.onToggle,
  });

  final RadioStation station;
  final bool saved;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    // 复用统一台标组件：目录里的 favicon 失败时自动落字母台标
    final ch = Channel(
      id: station.id,
      name: station.name,
      streamUrls: [station.url],
      logoUrl: station.favicon,
      categoryId: '',
      groupTitle: '',
      channelType: ChannelType.radio,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          ChannelBadge(channel: ch, size: 40, circular: true),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  station.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    if (station.subtitle.isNotEmpty) station.subtitle,
                    if (station.tagLine.isNotEmpty) station.tagLine,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GhostButton(
            icon: saved ? Icons.check_circle : Icons.add_circle_outline,
            tooltip: saved ? '从我的电台移除' : '加入我的电台',
            iconColor: saved ? AppColors.success : null,
            onPressed: onToggle,
          ),
        ],
      ),
    );
  }
}
