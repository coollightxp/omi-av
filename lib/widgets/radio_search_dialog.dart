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
import '../services/web_diag.dart';

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

  /// 「我的电台」列表自己的滚动控制器（两个列表不能共用同一个）
  final ScrollController _mineScroll = ScrollController();

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
    _mineScroll.dispose();
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

  /// 物理键是否还按着。同一颗键在收到 KeyUp 之前的任何 KeyDown 都是
  /// 重复（系统自动重复 / 接收器连发 / 多通道重复派发），一律吞掉。
  ///
  /// 用户实测「按一下 ↓ 走两行」：不靠时间窗猜（时间窗挡 30ms 的连发
  /// 可以，挡 200ms 的就会误伤正常连按），改按「有没有抬起来」判定——
  /// 一次按下只可能有一次 KeyDown。700ms 超时是防 KeyUp 丢事件
  /// （切窗口、焦点被抢、廉价接收器只发按下不发抬起）把键锁死。
  final Map<int, int> _physDownAt = {};

  /// 兜底：两路都完整发了 Down/Up（真正无法区分的重复）时，靠这个
  /// 60ms 窗口挡第二路；正常人手连按远慢于它，不会误伤。
  int _lastKeyId = 0;
  int _lastKeyAt = 0;

  KeyEventResult _handleKey(KeyEvent event) {
    if (!mounted) return KeyEventResult.ignored;
    final now = DateTime.now().millisecondsSinceEpoch;
    final phys = event.physicalKey.usbHidUsage;
    if (event is KeyUpEvent) {
      _physDownAt.remove(phys);
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final downAt = _physDownAt[phys];
    if (downAt != null && now - downAt < 700) {
      // 还没抬起就又按下：这就是"按一下跳两行 / 两行两行地跳"的来源
      WebDiag.log('radio_key dup phys=$phys lg=${event.logicalKey.debugName}');
      return KeyEventResult.handled;
    }
    _physDownAt[phys] = now;
    final k = event.logicalKey;
    if (k.keyId == _lastKeyId && now - _lastKeyAt < 60) {
      return KeyEventResult.handled;
    }
    _lastKeyId = k.keyId;
    _lastKeyAt = now;

    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      // 输入法正在组词时上下键归输入法（中文候选词选择）
      if (_imeComposing) return KeyEventResult.ignored;
      _moveRow(k == LogicalKeyboardKey.arrowDown ? 1 : -1);
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
      _moveCol(k == LogicalKeyboardKey.arrowRight ? 1 : -1);
      return KeyEventResult.handled;
    }
    // OK：**所有停靠点都在这里自己执行**，不再放行给控件。
    // 以前搜索按钮/「仅中国」/页签放给焦点树，控件激活的同时焦点还会
    // 被 Flutter 的默认遍历带走一格（用户实测：搜索按钮按 OK 跳到地区
    // 行、「仅中国」按 OK 跳到音乐分类），看起来就是"按哪都乱跳"。
    // 自己处理并返回 handled，焦点停在原地，动作只发生一次。
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
      // 搜索条：输入框 / 搜索按钮 / 仅中国。焦点一律不动——
      // 搜索是异步的，重建列表时焦点漂走就会出现"跳到筛选行"
      if (_queryFocus.hasFocus) {
        _search();
        return KeyEventResult.handled;
      }
      if (_searchBtnFocus.hasFocus) {
        if (!_loading) _search();
        return KeyEventResult.handled;
      }
      if (_cnFocus.hasFocus) {
        setState(() => _cnOnly = !_cnOnly);
        _search();
        return KeyEventResult.handled;
      }
      // 页签
      if (_tabSearchFocus.hasFocus) {
        _switchTab(0);
        return KeyEventResult.handled;
      }
      if (_tabMineFocus.hasFocus) {
        if (_tab == 1) {
          _focusMineList();
        } else {
          _switchTab(1);
        }
        return KeyEventResult.handled;
      }
      // 结果行 / 我的电台行：按 OK 等价于点行（加入 / 试听）
      if (_tab == 0) {
        for (final s in _results) {
          if (_rowNodeFor('search:${s.id}').hasFocus) {
            _toggle(s);
            return KeyEventResult.handled;
          }
        }
      } else {
        for (final s in RadioLibrary.items) {
          if (_rowNodeFor('mine:${s.id}').hasFocus) {
            _play(s);
            return KeyEventResult.handled;
          }
        }
      }
      return KeyEventResult.handled;
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

  // ==================== 行 / 列模型（与设置面板同一套规律）====================
  //
  // 界面上就是一行一行：
  //   0 页签行：搜索电台 / 我的电台
  //   1 搜索行：台名(地名)输入框 / 搜索图标 / 仅中国
  //   2 地区行：北京 上海 广东 浙江 …
  //   3 分类行：新闻 音乐 戏曲 …
  //   4.. 结果列表逐行；末尾一条「回到顶部 · 回搜索电台」
  //
  // 规则（用户定稿）：上下只走一行，进哪一行就停在这一行上；左右在本行内
  // 循环，搜索行最右再往右才换行到地区。
  //
  // 以前按「焦点树 + context 过滤」推位置：列表是懒构建的，视口外的行
  // context 为 null 被当成不存在而跳过，于是按一下跨两行（用户实测：
  // 中国之声 ↓ 跳过怀集音乐直接到国际新闻）。现在改成**行号驱动**——
  // 行号直接由列表下标算出来，没构建的行先滚过去再聚焦，位置关系永远是
  // 一行一格，与焦点树怎么建节点无关。

  /// 列表上方的头部行数：搜索页签有 页签/搜索/地区/分类 四行，
  /// 「我的电台」页签只有页签一行
  int get _headRows => _tab == 0 ? 4 : 1;

  int get _resultCount =>
      _tab == 0 ? _results.length : RadioLibrary.items.length;

  /// 列表末尾「回到顶部」的行号（只有搜索结果页签有这一行）
  int get _topRowIndex => _headRows + _results.length;

  int get _rowCount =>
      _headRows + _resultCount + (_tab == 0 && _results.isNotEmpty ? 1 : 0);

  /// 一次方向键只认一格：同一次按下被两条通道同时派发时，第二遍直接
  /// 丢掉（间隔只有几毫秒）。真正的重复按下由物理键配对挡在前面。
  int _lastMoveAt = 0;

  bool _moveGate() {
    final now = DateTime.now().millisecondsSinceEpoch;
    // 30ms 只够挡「同一按键被两路同时派发」，挡不住人手连按，不会误伤
    if (now - _lastMoveAt < 30) return false;
    _lastMoveAt = now;
    return true;
  }

  /// 当前焦点在第几行（沿祖先链找，落在输入法内部节点上也能认出来）
  int _currentRow() {
    FocusNode? cur = FocusManager.instance.primaryFocus;
    while (cur != null) {
      if (cur == _tabSearchFocus || cur == _tabMineFocus) return 0;
      if (cur == _queryFocus || cur == _searchBtnFocus || cur == _cnFocus) {
        return 1;
      }
      if (cur == _regionRow) return 2;
      if (cur == _tagRow) return 3;
      if (cur == _topRow) return _topRowIndex;
      if (_tab == 0) {
        for (var i = 0; i < _results.length; i++) {
          if (cur == _rowNodeFor('search:${_results[i].id}')) {
            return _headRows + i;
          }
        }
      } else {
        final items = RadioLibrary.items;
        for (var i = 0; i < items.length; i++) {
          if (cur == _rowNodeFor('mine:${items[i].id}')) {
            return _headRows + i;
          }
        }
      }
      cur = cur.parent;
    }
    return -1;
  }

  /// 上下走一行（循环：到底回页签，到顶回末尾，永远不会卡住）
  void _moveRow(int delta) {
    if (_rowCount <= 0) return;
    if (!_moveGate()) return;
    final cur = _currentRow();
    if (cur < 0) {
      _focusRow(0);
      return;
    }
    var next = (cur + delta) % _rowCount;
    if (next < 0) next += _rowCount;
    // 留痕：上下走位出问题时能直接从诊断日志看出「从哪行到哪行」，
    // 不用再靠猜（用户之前报「两行两行地跳」，正是缺这条）
    WebDiag.log('radio_row $cur->$next/$_rowCount');
    _focusRow(next);
  }

  /// 左右：只在本行内走，到头循环；搜索行最右再往右才换行
  void _moveCol(int dir) {
    if (!_moveGate()) return;
    final row = _currentRow();
    if (row < 0) return;
    if (row == 0) {
      // 页签行：左右就是切页
      _switchTab(_tab == 0 ? 1 : 0);
      return;
    }
    if (_tab == 0 && row == 1) {
      final cur = _barIndex < 0 ? 0 : _barIndex;
      final next = cur + dir;
      if (next > 2) {
        // 「仅中国」再往右 = 换行，落到地区行（用户要的出口）
        _regionRow.requestFocus();
        _ensureVisible();
        return;
      }
      if (next < 0) {
        // 输入框再往左：行内循环到「仅中国」
        _cnFocus.requestFocus();
        return;
      }
      [_queryFocus, _searchBtnFocus, _cnFocus][next].requestFocus();
      return;
    }
    if (_tab == 0 && row == 2) {
      _moveInRow(region: true, delta: dir);
      return;
    }
    if (_tab == 0 && row == 3) {
      _moveInRow(region: false, delta: dir);
      return;
    }
    if (_tab == 0 && row == _topRowIndex) {
      if (dir > 0) _backToTop();
      return;
    }
    // 结果列表任意一行按右：回列表最上边（长列表不用一路按 ↑）
    if (dir > 0) _jumpListTop();
  }

  /// 把焦点放到第 [row] 行的默认格上
  void _focusRow(int row) {
    if (row <= 0) {
      (_tab == 0 ? _tabSearchFocus : _tabMineFocus).requestFocus();
      _ensureVisible();
      return;
    }
    if (_tab == 0 && row == 1) {
      // 进搜索行一律落输入框：用户要的是「哪边上按下都到台名/地名框」，
      // 不是回到上次停留的搜索图标
      _queryFocus.requestFocus();
      _ensureVisible();
      return;
    }
    if (_tab == 0 && row == 2) {
      _regionRow.requestFocus();
      _ensureVisible();
      return;
    }
    if (_tab == 0 && row == 3) {
      _tagRow.requestFocus();
      _ensureVisible();
      return;
    }
    if (_tab == 0 && row == _topRowIndex) {
      _scrollThenFocus(null, () {
        _topRow.requestFocus();
        _ensureVisible();
      });
      return;
    }
    final i = row - _headRows;
    if (i < 0 || i >= _resultCount) return;
    final id = _tab == 0
        ? 'search:${_results[i].id}'
        : 'mine:${RadioLibrary.items[i].id}';
    final node = _rowNodeFor(id);
    if (node.context != null) {
      node.requestFocus();
      _ensureVisible();
      return;
    }
    // 目标行还在视口外没构建：先滚过去，下一帧再聚焦
    _scrollThenFocus(i, () {
      if (node.context != null) {
        node.requestFocus();
        _ensureVisible();
      }
    });
  }

  /// 列表滚到第 [index] 行附近（null = 滚到底），下一帧执行 [then]
  void _scrollThenFocus(int? index, VoidCallback then) {
    final sc = _tab == 0 ? _resultScroll : _mineScroll;
    if (sc.hasClients) {
      final h = _measuredRowHeight();
      final target = index == null
          ? sc.position.maxScrollExtent
          : (index * h - 2 * h).clamp(0.0, sc.position.maxScrollExtent);
      sc.jumpTo(target);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      then();
    });
  }

  /// 实测一行多高（含分隔线），取前几行里能量到的那个
  double _measuredRowHeight() {
    final ids = _tab == 0
        ? [for (final s in _results.take(3)) 'search:${s.id}']
        : [for (final s in RadioLibrary.items.take(3)) 'mine:${s.id}'];
    for (final id in ids) {
      final ro = _rowNodeFor(id).context?.findRenderObject();
      if (ro is RenderBox && ro.size.height > 8) return ro.size.height + 1;
    }
    return 56;
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

  /// 列表里按右：焦点回第一行、列表滚回顶部。
  /// 只回列表顶、不跳回页签——用户按右是为了接着从上往下挑，
  /// 要回页签用 ↑ 或末尾那条「回到顶部」。
  void _jumpListTop() {
    if (_resultCount == 0) return;
    _focusRow(_headRows);
    final scroller = _tab == 0 ? _resultScroll : _mineScroll;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (scroller.hasClients) scroller.jumpTo(0);
    });
  }

  /// 「我的电台」页签上按 OK：焦点进卡片，落到第一台
  void _focusMineList() {
    if (RadioLibrary.items.isEmpty) return;
    _focusRow(_headRows);
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
    (_tab == 0 ? _tabSearchFocus : _tabMineFocus).requestFocus();
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
          // 关闭 ✕ 不进焦点序列：遥控器的出口是返回键/菜单键，
          // 焦点停在这颗叉上没有意义，还会让上下走位多一跳
          ExcludeFocus(
            child: GhostButton(
              icon: Icons.close,
              tooltip: '关闭',
              onPressed: () => Navigator.pop(context),
            ),
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
            controller: _mineScroll,
            padding: const EdgeInsets.only(bottom: 8),
            // 同搜索结果列表：缓存给足，紧邻行一定已构建，上下只走一格
            cacheExtent: 800,
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
      // 预构建视口外上下各一大段（约 10 行）：上下移动时紧邻的那一行
      // 必定已经在树上，_focusRow 不用先滚动就能直接聚焦，手感不卡。
      cacheExtent: 800,
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
