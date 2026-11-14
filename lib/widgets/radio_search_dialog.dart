import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ime_safe_text_field.dart';
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

  /// 弹窗是否打开。player_screen 的「弹层统一收口」据此放行按键——
  /// 否则方向键被吞掉、OK 还会直接把弹窗关掉，遥控器根本没法在里面选台。
  static bool active = false;

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

  /// 焦点树根：只用于按键分发与「按控件树顺序上下走」，自己不取焦点
  final FocusNode _rootFocus = FocusNode(
    debugLabel: 'radioDialogRoot',
    skipTraversal: true,
    canRequestFocus: false,
  );
  final FocusNode _tabSearchFocus = FocusNode(debugLabel: 'radioTabSearch');
  final FocusNode _tabMineFocus = FocusNode(debugLabel: 'radioTabMine');

  /// 搜索条三个控件的焦点：输入框 → 搜索 → 仅中国，左右键按这个顺序走
  /// （用户定义的操作顺序，上下键也走同一条线）
  final FocusNode _searchBtnFocus = FocusNode(debugLabel: 'radioSearchBtn');
  final FocusNode _cnFocus = FocusNode(debugLabel: 'radioCnOnly');

  /// 快捷筛选拆成两行（地区一行、分类一行），**每行只占一个焦点停靠点**：
  /// 行内左右换 chip、OK 过滤，上下在行与行之间走。以前两排混成一条横排
  /// 且每个 chip 都是停靠点，上下要按十几次 chip 才下得去，遥控器上就是
  /// "乱跳"（用户实测）。
  final FocusNode _regionRow = FocusNode(debugLabel: 'radioRegionRow');
  final FocusNode _tagRow = FocusNode(debugLabel: 'radioTagRow');

  /// 列表末尾「回到顶部」：长列表按到底之后，遥控器没有别的出口能回去
  final FocusNode _topRow = FocusNode(debugLabel: 'radioBackToTop');

  /// 行内光标位置（左右键改的是它，OK 才真正过滤）
  int _regionIdx = 0;
  int _tagIdx = 0;

  /// chip 的 GlobalKey：左右移动时把它滚进可视区
  final Map<String, GlobalKey> _chipKeys = {};

  /// 结果列表滚动控制器：回到顶部要能把列表也拉回去
  final ScrollController _resultScroll = ScrollController();

  /// 列表行焦点按台 id 复用：列表重建不丢焦点，遥控器不会跳回顶部
  final Map<String, FocusNode> _rowFocus = {};

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
    RadioSearchDialog.active = true;
    // 行焦点进出都要重画（行内光标态靠 hasFocus 判断）
    for (final n in [_regionRow, _tagRow]) {
      n.addListener(() {
        if (mounted) setState(() {});
      });
    }
    // 方向键/OK 走硬件层：比焦点树更早拿到按键，保证遥控器一定能操作
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    // 内置索引只有几 KB，先读起来，搜索结果才能标「内置」
    BuiltinRadioIndex.ensure().then((_) {
      if (mounted) setState(() {});
    });
    // 首屏给中国区热门，避免面对空白
    _search();
    // 进来第一件事：焦点落在「搜索电台」页签上（不等搜索结果回来，
    // 网络慢时也不会出现"焦点悬空、按哪都不动"的一段空窗）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tabSearchFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    RadioSearchDialog.active = false;
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _queryCtl.dispose();
    _queryFocus.dispose();
    _rootFocus.dispose();
    _tabSearchFocus.dispose();
    _tabMineFocus.dispose();
    _searchBtnFocus.dispose();
    _cnFocus.dispose();
    _regionRow.dispose();
    _tagRow.dispose();
    _topRow.dispose();
    _resultScroll.dispose();
    for (final n in _rowFocus.values) {
      n.dispose();
    }
    super.dispose();
  }

  // ==================== 遥控器 / 键盘导航 ====================

  FocusNode _rowNodeFor(String id) =>
      _rowFocus.putIfAbsent(id, () => FocusNode(debugLabel: 'radioRow:$id'));

  bool _onHardwareKey(KeyEvent event) =>
      _handleKey(event) == KeyEventResult.handled;

  KeyEventResult _handleKey(KeyEvent event) {
    if (!mounted) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;

    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      // 输入法正在组词时上下键归输入法（中文候选词选择）
      if (_imeComposing) return KeyEventResult.ignored;
      _moveVertical(up: k == LogicalKeyboardKey.arrowUp);
      return KeyEventResult.handled;
    }
    // 返回 / 菜单键：关弹窗（遥控器没有鼠标，必须有键盘出口）
    if (k == LogicalKeyboardKey.escape ||
        k == LogicalKeyboardKey.contextMenu ||
        k == LogicalKeyboardKey.goBack) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.arrowRight) {
      if (_imeComposing) return KeyEventResult.ignored;
      final left = k == LogicalKeyboardKey.arrowLeft;
      // 筛选行内：左右换 chip（循环），OK 才过滤
      if (_regionRow.hasFocus) {
        _moveInRow(region: true, delta: left ? -1 : 1);
        return KeyEventResult.handled;
      }
      if (_tagRow.hasFocus) {
        _moveInRow(region: false, delta: left ? -1 : 1);
        return KeyEventResult.handled;
      }
      // 列表末尾「回到顶部」：往右就是出口（用户要求的"这一行往右退出"）
      if (_topRow.hasFocus && !left) {
        _backToTop();
        return KeyEventResult.handled;
      }
      // 搜索条内：输入框 ←→ 搜索按钮 ←→ 仅中国
      final bar = _barIndex;
      if (bar >= 0) {
        final next = (bar + (left ? -1 : 1)).clamp(0, 2);
        [_queryFocus, _searchBtnFocus, _cnFocus][next].requestFocus();
        return KeyEventResult.handled;
      }
      // 页签上左右切页
      final p = FocusManager.instance.primaryFocus;
      if (p == _tabSearchFocus || p == _tabMineFocus) {
        _switchTab(p == _tabSearchFocus ? 1 : 0);
        return KeyEventResult.handled;
      }
      // 其余控件没有横向兄弟：左右一律吞掉。以前放行会给 Flutter 默认
      // 方向导航，焦点横向窜到别的控件上，遥控器感觉像"乱跳"
      return KeyEventResult.handled;
    }
    // OK：筛选行/回顶行/页签这几类"自绘焦点"自己处理；其它控件放行给
    // 焦点树（输入框回车、列表行 OK、按钮等各管各的）
    if (k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.gameButtonA) {
      if (_regionRow.hasFocus) {
        _activateRegion(_regionIdx);
        return KeyEventResult.handled;
      }
      if (_tagRow.hasFocus) {
        _activateTag(_tagIdx);
        return KeyEventResult.handled;
      }
      if (_topRow.hasFocus) {
        _backToTop();
        return KeyEventResult.handled;
      }
      // 我的电台页签上按 OK：进卡片里（焦点落到第一台）
      if (_tab == 1 && _tabMineFocus.hasFocus) {
        _focusMineList();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  /// 搜索条里当前焦点在哪一格：0 输入框 / 1 搜索 / 2 仅中国 / -1 不在条上
  int get _barIndex {
    if (_queryFocus.hasFocus) return 0;
    if (_searchBtnFocus.hasFocus) return 1;
    if (_cnFocus.hasFocus) return 2;
    return -1;
  }

  /// 输入法是否正在组词（组词期间不能抢上下键）
  bool get _imeComposing {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    final et = ctx.findAncestorWidgetOfExactType<EditableText>();
    if (et == null) return false;
    final c = et.controller.value.composing;
    return c.isValid && !c.isCollapsed;
  }

  /// 上下：按控件树顺序走一格，**到头绕回**（与设置页内容区同一套逻辑：
  /// 上下只在本卡片里循环，永远不会掉进/掉出别的控件）
  void _moveVertical({required bool up}) {
    final stops = _navStops();
    if (stops.isEmpty) return;
    final idx = _stopIndexOf(stops, FocusManager.instance.primaryFocus);
    if (idx < 0) {
      stops.first.requestFocus();
      _ensureVisible();
      return;
    }
    // Dart 的 % 对负数返回非负值，绕回不用额外判断
    final next = (idx + (up ? -1 : 1)) % stops.length;
    stops[next].requestFocus();
    _ensureVisible();
  }

  /// 上下导航的停靠点（树顺序，与界面自上而下一致）。
  ///
  /// 搜索框也算停靠点：遥控器/键盘要能「页签 → 搜索框 → 搜索按钮 →
  /// 城市筛选 → 结果列表」一路走下来。输入法组词期间上下键会放行给
  /// 候选词（见 _imeComposing），所以不会被困在框里出不来。
  ///
  /// 只保留最外层：行/按钮内部还会再建焦点节点，不去重会出现同一行
  /// 停两次、顺序看起来乱蹦。
  List<FocusNode> _navStops() {
    final all = <FocusNode>[];
    for (final n in _rootFocus.traversalDescendants) {
      if (!n.canRequestFocus || n.context == null) continue;
      all.add(n);
    }
    final keep = <FocusNode>[];
    for (final n in all) {
      var p = n.parent;
      var nested = false;
      while (p != null) {
        if (keep.contains(p)) {
          nested = true;
          break;
        }
        p = p.parent;
      }
      if (!nested) keep.add(n);
    }
    return keep;
  }

  /// 当前焦点在停靠点里的位置：焦点常落在子节点上（输入框内的
  /// EditableText、按钮内部的 InkWell），要沿祖先链找最近的停靠点，
  /// 否则会被当成"不在列表里"而跳到头/尾——遥控器感觉就是乱跳
  int _stopIndexOf(List<FocusNode> stops, FocusNode? from) {
    var cur = from;
    while (cur != null) {
      final i = stops.indexOf(cur);
      if (i >= 0) return i;
      cur = cur.parent;
    }
    return -1;
  }

  /// 筛选行内左右移动光标（循环）。focus 在行节点上，具体 chip 靠下标记录，
  /// 所以这里要顺手把目标 chip 滚进可视区（遥控器看不到屏幕外的光标）。
  void _moveInRow({required bool region, required int delta}) {
    final n = region
        ? RadioDirectory.quickRegions.length
        : RadioDirectory.quickTags.length;
    if (n == 0) return;
    setState(() {
      if (region) {
        _regionIdx = (_regionIdx + delta) % n;
        if (_regionIdx < 0) _regionIdx += n;
      } else {
        _tagIdx = (_tagIdx + delta) % n;
        if (_tagIdx < 0) _tagIdx += n;
      }
    });
    final key = _chipKeys[region ? 'r$_regionIdx' : 't$_tagIdx'];
    final ctx = key?.currentContext;
    if (ctx != null && ctx.mounted) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 120),
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    }
  }

  void _activateRegion(int i) {
    if (i < 0 || i >= RadioDirectory.quickRegions.length) return;
    final city = RadioDirectory.quickRegions[i];
    final on = _queryCtl.text.trim() == city && _tag.isEmpty;
    if (on) {
      _queryCtl.clear();
      _search();
    } else {
      _queryCtl.text = city;
      setState(() => _tag = '');
      _search();
    }
  }

  void _activateTag(int i) {
    if (i < 0 || i >= RadioDirectory.quickTags.length) return;
    final tag = RadioDirectory.quickTags[i].$2;
    final on = _tag == tag;
    _queryCtl.clear();
    _search(tag: on ? '' : tag);
  }

  /// 长列表到底后的出口：回滚列表 + 焦点回到「搜索电台」页签
  void _backToTop() {
    _tabSearchFocus.requestFocus();
    if (_resultScroll.hasClients) {
      _resultScroll.animateTo(
        0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  /// 「我的电台」页签上按 OK：焦点进卡片，落到第一台
  void _focusMineList() {
    final items = RadioLibrary.items;
    if (items.isEmpty) return;
    _rowNodeFor('mine:${items.first.id}').requestFocus();
  }

  void _ensureVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = FocusManager.instance.primaryFocus?.context;
      if (ctx == null || !ctx.mounted) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 120),
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  void _switchTab(int i) {
    if (_tab == i) return;
    setState(() => _tab = i);
    (i == 0 ? _tabSearchFocus : _tabMineFocus).requestFocus();
  }

  /// 打开时把焦点放到第一个可选项：遥控器进来就能直接上下选
  void _focusFirstReady() {
    final stops = _navStops();
    if (stops.isNotEmpty) stops.first.requestFocus();
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
      // 结果回来后如果焦点还悬空（刚打开弹窗），落到第一个可操作项上：
      // 遥控器打开就能直接按上下选台
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final p = FocusManager.instance.primaryFocus;
        if (p == null || p == _rootFocus || !p.hasFocus) _focusFirstReady();
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
      OsdBus.show('已加入左侧「电台 · 我的电台」：${s.name}', icon: Icons.playlist_add_check);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    // 遥控器 OK 通常发 select，Flutter 默认只认 Enter/Space：
    // 这里把 select / 手柄 A / 小键盘回车都映射成「激活当前焦点项」
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
      },
      child: FocusTraversalGroup(
        policy: WidgetOrderTraversalPolicy(),
        child: Focus(
          focusNode: _rootFocus,
          // 注意：按键只走 HardwareKeyboard 通道（initState 里注册的
          // _onHardwareKey）。这里不能挂 onKeyEvent——两条通道会对同一个
          // 按键各执行一次 _handleKey，遥控器按一下左右就跳两格
          // （2026-11-14 用户实测：地区/分类两行"两个两个跳"）
          child: Dialog(
            backgroundColor: Colors.transparent,
            insetPadding:
                const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
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
                    _filterRows(),
                    const Divider(color: AppColors.divider, height: 1),
                  ],
                  Expanded(child: _tab == 0 ? _resultArea() : _mineArea()),
                ],
              ),
            ),
          ),
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
              '加入后就在左侧「频道列表 → 电台 → 我的电台」，随时可删',
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
    return _FocusCard(
      focusNode: index == 0 ? _tabSearchFocus : _tabMineFocus,
      onActivate: () => _switchTab(index),
      radius: 8,
      child: InkWell(
        onTap: () => _switchTab(index),
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
                focusNode: _rowNodeFor('mine:${s.id}'),
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
              child: ImeSafeTextField(
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
            focusNode: _searchBtnFocus,
            onPressed: _loading ? null : () => _search(),
          ),
          const SizedBox(width: 4),
          // 仅中国：默认开，搜"音乐"不会出来一堆国外台
          FilterChip(
            focusNode: _cnFocus,
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

  /// 两行筛选：地区 / 分类。
  ///
  /// 每行只占一个焦点停靠点（行内左右换 chip、OK 过滤），上下键直接
  /// 在「地区行 → 分类行 → 结果列表」之间走——以前两排混成一条横排，
  /// 每个 chip 都是停靠点，遥控器要按十几次才下得去。
  Widget _filterRows() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      child: Column(
        children: [
          _filterRow(
            label: '地区',
            node: _regionRow,
            count: RadioDirectory.quickRegions.length,
            chip: (i) {
              final city = RadioDirectory.quickRegions[i];
              return _filterChip(
                keyId: 'r$i',
                label: city,
                selected: _queryCtl.text.trim() == city && _tag.isEmpty,
                cursor: _regionRow.hasFocus && _regionIdx == i,
                onTap: () {
                  _regionRow.requestFocus();
                  setState(() => _regionIdx = i);
                  _activateRegion(i);
                },
              );
            },
          ),
          const SizedBox(height: 6),
          _filterRow(
            label: '分类',
            node: _tagRow,
            count: RadioDirectory.quickTags.length,
            chip: (i) {
              final (label, tag) = RadioDirectory.quickTags[i];
              return _filterChip(
                keyId: 't$i',
                label: label,
                selected: _tag == tag,
                cursor: _tagRow.hasFocus && _tagIdx == i,
                onTap: () {
                  _tagRow.requestFocus();
                  setState(() => _tagIdx = i);
                  _activateTag(i);
                },
              );
            },
          ),
        ],
      ),
    );
  }

  /// 一行筛选：左侧小标签 + 横向滚动的 chip 条
  Widget _filterRow({
    required String label,
    required FocusNode node,
    required int count,
    required Widget Function(int) chip,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 34,
          child: Text(
            label,
            style:
                const TextStyle(color: AppColors.textTertiary, fontSize: 11.5),
          ),
        ),
        Expanded(
          child: Focus(
            focusNode: node,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: node.hasFocus ? Colors.white70 : Colors.transparent,
                ),
              ),
              child: ScrollConfiguration(
                // 桌面端 Flutter 默认不允许鼠标拖动滚动：这排挺长，
                // 按住鼠标往左拖完全不动（只能滚滚轮），体验很别扭
                behavior: const _DragScrollBehavior(),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (var i = 0; i < count; i++) ...[
                        if (i > 0) const SizedBox(width: 6),
                        chip(i),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 一个筛选 chip：选中=主色 + 对号；光标（行有焦点且停在这颗上）=白框
  Widget _filterChip({
    required String keyId,
    required String label,
    required bool selected,
    required bool cursor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      key: _chipKeys.putIfAbsent(keyId, () => GlobalKey()),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accent.withValues(alpha: 0.24)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: cursor
                ? Colors.white
                : (selected ? AppColors.accent : AppColors.stroke),
            width: cursor ? 2 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected) ...[
              const Icon(Icons.check, size: 12, color: AppColors.textPrimary),
              const SizedBox(width: 3),
            ],
            Text(
              label,
              style: TextStyle(
                color:
                    selected ? AppColors.textPrimary : AppColors.textSecondary,
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 结果列表末尾的出口行：OK 或「右」都回顶部（列表 + 焦点一起回去）
  Widget _backToTopRow() {
    return _FocusCard(
      focusNode: _topRow,
      onActivate: _backToTop,
      radius: 8,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            const Icon(Icons.vertical_align_top,
                size: 18, color: AppColors.textTertiary),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                '回到顶部 · 回「搜索电台」',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
            ),
            Text(
              'OK / →',
              style: TextStyle(
                color: AppColors.textTertiary.withValues(alpha: 0.9),
                fontSize: 11.5,
              ),
            ),
          ],
        ),
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
      controller: _resultScroll,
      padding: const EdgeInsets.symmetric(vertical: 4),
      // 多一行「回到顶部」：长列表按到底后，遥控器没有别的出口回得去
      // （用户实测：按到底再往回返，返不回最顶上）
      itemCount: _results.length + 1,
      separatorBuilder: (_, __) =>
          const Divider(color: AppColors.divider, height: 1),
      itemBuilder: (context, i) {
        if (i == _results.length) return _backToTopRow();
        final s = _results[i];
        final saved = controller.isStationSaved(s.id);
        return _StationRow(
          station: s,
          saved: saved,
          builtin: _builtinIds.contains(s.id),
          focusNode: _rowNodeFor('search:${s.id}'),
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
    required this.focusNode,
    required this.onToggle,
  });

  final RadioStation station;
  final bool saved;

  /// 内置精选里已有这个台：不给「加入」，避免同一台在列表里出现两份
  final bool builtin;

  /// 行焦点：遥控器/键盘上下停靠，OK 直接加入或移除
  final FocusNode focusNode;
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
    return _FocusCard(
      focusNode: focusNode,
      // 内置台已在内置精选里，没有「加入」动作：焦点可停，按 OK 无操作
      onActivate: builtin ? null : onToggle,
      radius: 8,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppColors.stroke),
                  ),
                  child: const Text(
                    '内置',
                    style: TextStyle(
                        color: AppColors.textTertiary, fontSize: 11.5),
                  ),
                ),
              )
            else
              // 按钮不单独参与焦点遍历：整行就是一个操作入口，
              // 遥控器在行上按 OK 即等价于点这个 + 号
              ExcludeFocus(
                child: GhostButton(
                  icon: saved ? Icons.check_circle : Icons.add_circle_outline,
                  tooltip: saved ? '从我的电台移除' : '加入我的电台',
                  iconColor: saved ? AppColors.success : null,
                  onPressed: onToggle,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 「我的电台」里的一行：点行=试听，右侧叉=移除
class _MineRow extends StatelessWidget {
  const _MineRow({
    required this.station,
    required this.playing,
    required this.focusNode,
    required this.onPlay,
    required this.onRemove,
  });

  final RadioStation station;
  final bool playing;

  /// 行焦点：遥控器上下停靠，OK 直接试听
  final FocusNode focusNode;
  final VoidCallback onPlay;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final ch = RadioLibrary.toChannel(station);
    return _FocusCard(
      focusNode: focusNode,
      onActivate: onPlay,
      radius: 8,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: InkWell(
        onTap: onPlay,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 7, 4, 7),
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
              // 行本身就是「试听」入口，按钮不再单独占焦点停靠点
              ExcludeFocus(
                child: GhostButton(
                  icon: playing ? Icons.graphic_eq : Icons.play_arrow,
                  tooltip: playing ? '正在播放' : '试听',
                  iconColor: playing ? AppColors.wave : null,
                  onPressed: onPlay,
                ),
              ),
              ExcludeFocus(
                child: GhostButton(
                  icon: Icons.close,
                  tooltip: '从我的电台移除（遥控器：焦点到此行按 OK 是试听）',
                  onPressed: onRemove,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 桌面端允许鼠标拖动滚动。
///
/// Flutter 默认的 ScrollBehavior 只把触摸/触控板当拖动设备，鼠标按住拖动
/// 完全不响应（只能滚滚轮）。这个弹窗里的快捷筛选是横向长条，用户很自然
/// 会按住往左拖，必须放开这个限制。
class _DragScrollBehavior extends MaterialScrollBehavior {
  const _DragScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.stylus,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.invertedStylus,
      };
}

/// 遥控器 / 键盘焦点包装：可聚焦 + OK 激活 + 焦点描边。
///
/// 弹窗里所有可操作项都套一层，解决三件事：
/// 1. 遥控器方向键有明确的停靠点（悬浮列表 / 快捷筛选 / 页签）；
/// 2. 遥控器 OK（发 select 键）能被识别成「点击」——Flutter 默认只认
///    Enter/Space，电视遥控器按下毫无反应；
/// 3. 走到哪一眼看得出来（描边 + 淡淡底色），不用猜焦点在哪。
class _FocusCard extends StatelessWidget {
  const _FocusCard({
    required this.focusNode,
    required this.onActivate,
    required this.child,
    this.radius = 10,
    this.padding = EdgeInsets.zero,
  });

  final FocusNode focusNode;
  final VoidCallback? onActivate;
  final Widget child;
  final double radius;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      focusNode: focusNode,
      mouseCursor: SystemMouseCursors.click,
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onActivate?.call();
            return null;
          },
        ),
      },
      child: Padding(
        padding: padding,
        child: Builder(builder: (ctx) {
          final focused = Focus.of(ctx).hasFocus;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 110),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(
                color: focused ? AppColors.accent : Colors.transparent,
                width: 1.5,
              ),
              color: focused
                  ? AppColors.accent.withValues(alpha: 0.10)
                  : Colors.transparent,
            ),
            child: child,
          );
        }),
      ),
    );
  }
}
