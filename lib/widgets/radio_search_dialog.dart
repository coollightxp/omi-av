import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/app_colors.dart';
import '../core/widgets/audio_wave.dart';
import '../core/widgets/channel_badge.dart';
import '../core/widgets/ghost_button.dart';
import '../models/channel.dart';
import '../models/radio_station.dart';
import '../services/osd_bus.dart';
import '../services/player_controller.dart';
import '../services/builtin_radio_index.dart';
import '../services/radio_directory.dart';
import '../services/radio_library.dart';

/// 在线电台搜索（Radio Browser 目录）。
///
/// 两块内容：
/// ①「搜索」——Radio Browser 目录，搜到哪台加哪台，加进「我的电台」；
///    已在内置精选里的台标「内置」，不给重复添加按钮。
/// ②「我的电台」——已加的台在这里集中管理：点一下直接试听、叉掉即删、可清空。
///
/// 与「收藏」的分工：收藏是给任意源里任意频道打的星标（跨源、按频道 id 存）；
/// 这里是真正把台**加进源列表**，成为「我的电台」源里的一个频道。
/// 出厂自带的 60 个台不出现在这里、也不能删（要整源移除用设置页的删除）。
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

  /// 0=搜索 1=我的电台
  int _tab = 0;

  /// 搜索结果里哪些台已经在内置精选里（按 station id 记）
  Set<String> _builtinIds = {};

  @override
  void initState() {
    super.initState();
    // 内置索引只有几 KB，先读起来，搜索结果才能标「内置」
    BuiltinRadioIndex.ensure().then((_) {
      if (mounted) setState(() {});
    });
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
      await BuiltinRadioIndex.ensure();
      if (!mounted) return;
      setState(() {
        _results = list;
        _builtinIds = {
          for (final s in list)
            if (BuiltinRadioIndex.contains(name: s.name, url: s.url)) s.id,
        };
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
            _tabBar(),
            const Divider(color: AppColors.divider, height: 1),
            if (_tab == 0) ...[
              _searchBar(),
              _tagBar(),
              const Divider(color: AppColors.divider, height: 1),
            ],
            Expanded(child: _tab == 0 ? _resultArea() : _mineArea()),
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

  // ==================== 页签 ====================

  Widget _tabBar() {
    final n = RadioLibrary.count;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Row(
        children: [
          _tabChip(0, '搜索电台', Icons.search),
          const SizedBox(width: 8),
          _tabChip(1, n > 0 ? '我的电台 · $n' : '我的电台', Icons.library_music),
        ],
      ),
    );
  }

  Widget _tabChip(int index, String label, IconData icon) {
    final on = _tab == index;
    return InkWell(
      onTap: () => setState(() => _tab = index),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: on
              ? AppColors.accent.withValues(alpha: 0.20)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: on ? AppColors.accent : AppColors.stroke,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 15,
                color: on ? AppColors.textPrimary : AppColors.textTertiary),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: on ? FontWeight.w600 : FontWeight.w500,
                color: on ? AppColors.textPrimary : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== 我的电台（管理） ====================

  Widget _mineArea() {
    final items = RadioLibrary.items;
    if (items.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.library_music_outlined,
                  color: AppColors.textTertiary, size: 40),
              SizedBox(height: 14),
              Text(
                '还没有自己的电台\n在「搜索电台」里找到台后点 + 就加到这里',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: AppColors.textTertiary, fontSize: 13, height: 1.6),
              ),
            ],
          ),
        ),
      );
    }
    final c = context.watch<PlayerController>();
    final playingId = c.currentChannel?.id;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '共 ${items.length} 个 · 点一下直接试听，叉掉即移除',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppColors.textTertiary, fontSize: 11.5),
                ),
              ),
              TextButton.icon(
                onPressed: () => _clearAll(),
                icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                label: const Text('清空', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.textTertiary,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.only(bottom: 8),
            itemCount: items.length,
            separatorBuilder: (_, __) =>
                const Divider(color: AppColors.divider, height: 1),
            itemBuilder: (context, i) {
              final s = items[i];
              return _MineRow(
                station: s,
                playing: playingId == RadioLibrary.channelIdOf(s.id),
                onPlay: () => _play(s),
                onRemove: () => _toggle(s),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _play(RadioStation s) async {
    final c = context.read<PlayerController>();
    await c.playChannel(RadioLibrary.toChannel(s));
    if (!mounted) return;
    OsdBus.show('正在收听：${s.name}', icon: Icons.play_arrow);
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: AppColors.scrim,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.overlay,
        title: const Text('清空我的电台？',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
        content: Text(
          '将从「我的电台」移除全部 ${RadioLibrary.count} 个台。'
          '内置精选与电视源不受影响，随时可以在搜索里重新加入。',
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空', style: TextStyle(color: AppColors.live)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final c = context.read<PlayerController>();
    for (final s in List.of(RadioLibrary.items)) {
      await c.removeRadioStation(s.id);
    }
    if (!mounted) return;
    setState(() {});
    OsdBus.show('已清空我的电台', icon: Icons.delete_sweep_outlined);
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
                  hintText: '台名或地名，如「中国之声」「上海」',
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
          // 地名：点一下直接按地名搜（比让用户自己敲"上海"更顺手）
          for (final city in RadioDirectory.quickRegions) ...[
            if (city != RadioDirectory.quickRegions.first)
              const SizedBox(width: 6),
            _cityChip(city),
          ],
          const SizedBox(width: 10),
          Container(width: 1, height: 18, color: AppColors.divider),
          const SizedBox(width: 10),
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

  /// 地名 chip：选中态看「输入框里正好是这个地名」
  Widget _cityChip(String city) {
    final on = _queryCtl.text.trim() == city && _tag.isEmpty;
    return ChoiceChip(
      label: Text(city, style: const TextStyle(fontSize: 12)),
      selected: on,
      onSelected: (_) {
        if (on) {
          _queryCtl.clear();
          _search();
        } else {
          _queryCtl.text = city;
          setState(() => _tag = '');
          _search();
        }
      },
      selectedColor: AppColors.accent.withValues(alpha: 0.25),
      backgroundColor: Colors.white.withValues(alpha: 0.04),
      side: const BorderSide(color: AppColors.stroke),
      checkmarkColor: AppColors.textPrimary,
      labelStyle: TextStyle(
        color: on ? AppColors.textPrimary : AppColors.textSecondary,
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
          style: const TextStyle(color: AppColors.textTertiary, fontSize: 13),
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
          builtin: _builtinIds.contains(s.id),
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
    required this.builtin,
    required this.onToggle,
  });

  final RadioStation station;
  final bool saved;

  /// 内置精选里已有这个台：不给「加入」，避免同一台在列表里出现两份
  final bool builtin;
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
          if (builtin)
            Tooltip(
              message: '已在「内置电台精选」里，直接在频道列表收听',
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppColors.stroke),
                ),
                child: const Text(
                  '内置',
                  style:
                      TextStyle(color: AppColors.textTertiary, fontSize: 11.5),
                ),
              ),
            )
          else
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

/// 「我的电台」里的一行：点行=试听，右侧叉=移除
class _MineRow extends StatelessWidget {
  const _MineRow({
    required this.station,
    required this.playing,
    required this.onPlay,
    required this.onRemove,
  });

  final RadioStation station;
  final bool playing;
  final VoidCallback onPlay;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final ch = RadioLibrary.toChannel(station);
    return InkWell(
      onTap: onPlay,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
        child: Row(
          children: [
            ChannelBadge(channel: ch, size: 40, circular: true),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          station.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: playing
                                ? AppColors.wave
                                : AppColors.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (playing) ...[
                        const SizedBox(width: 8),
                        const AudioBars(active: true, height: 11, bars: 3),
                      ],
                    ],
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
            const SizedBox(width: 6),
            GhostButton(
              icon: playing ? Icons.graphic_eq : Icons.play_arrow,
              tooltip: playing ? '正在播放' : '试听',
              iconColor: playing ? AppColors.wave : null,
              onPressed: onPlay,
            ),
            GhostButton(
              icon: Icons.close,
              tooltip: '从我的电台移除',
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}
