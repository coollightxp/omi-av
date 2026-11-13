import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'dart:io' show File, FileStat, Platform;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:window_manager/window_manager.dart';

import '../core/theme/app_colors.dart';
import '../models/channel.dart';
import '../models/epg_source.dart';
import 'radio_search_dialog.dart';
import '../models/player_settings.dart';
import '../models/playlist_source.dart';
import '../services/osd_bus.dart';
import '../services/player_controller.dart';
import '../services/channel_blacklist.dart';
import '../services/channel_alias.dart';
import '../services/scene_favorites.dart';
import '../services/radio_recorder.dart';
import '../services/recording_share.dart';
import '../services/radio_library.dart';
import '../services/web_diag.dart';
import 'ime_safe_text_field.dart';
import 'scaled_panel.dart';

export 'ime_safe_text_field.dart' show ImeSafeTextField;

typedef _ImeSafeTextField = ImeSafeTextField;

/// 选择本地文件。
/// Windows 上主窗口默认置顶（全屏时强制置顶），而 file_picker 的系统
/// 文件对话框（IFileDialog）不会自动成为置顶窗口，会被压在主窗口
/// 后面、任务栏也只闪图标。弹出前临时取消置顶，对话框关闭后恢复。
Future<PlatformFile?> _pickLocalFileWithTopmostFix() async {
  bool wasTopmost = false;
  try {
    wasTopmost = await windowManager.isAlwaysOnTop();
    if (wasTopmost) {
      await windowManager.setAlwaysOnTop(false);
      // 等窗口管理器应用完层级变更，避免对话框仍被盖住
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
  } catch (_) {
    wasTopmost = false;
  }
  try {
    return await FilePicker.pickFile(type: FileType.any);
  } finally {
    if (wasTopmost) {
      try {
        await windowManager.setAlwaysOnTop(true);
      } catch (_) {}
    }
  }
}

/// 设置面板 - 从底部弹出的设置菜单
/// 包含三个标签页：播放列表、EPG、播放器设置
class SettingsPanel extends StatefulWidget {
  final bool isOpen;
  final VoidCallback onClose;

  const SettingsPanel({
    super.key,
    required this.isOpen,
    required this.onClose,
  });

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  /// 顶部页签的焦点节点：上下键可以落到这里，左右键在这里切页签
  final FocusNode _navFocus = FocusNode(debugLabel: 'settingsTabBar');

  /// 设置内容根节点：判断当前焦点是否已在面板内
  final GlobalKey _panelKey = GlobalKey();

  /// 面板根焦点节点：上下键在这里统一处理。它自己不取焦点、不参与遍历，
  /// 只是包住全部内容，让按键一定能先在面板内处理掉（不依赖
  /// HardwareKeyboard 处理器顺序）
  final FocusNode _panelFocusNode = FocusNode(
    debugLabel: 'settingsPanelRoot',
    skipTraversal: true,
    canRequestFocus: false,
  );

  /// 设置变化的独立订阅（不再依赖 PlayerController.notifyListeners，
  /// 否则每次拨开关都会重建整个播放树，正在播时就是"卡一下"）
  PlayerController? _settingsOwner;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = context.read<PlayerController>();
    if (!identical(c, _settingsOwner)) {
      _settingsOwner?.settingsNotifier.removeListener(_onSettingsChanged);
      _settingsOwner = c;
      c.settingsNotifier.addListener(_onSettingsChanged);
    }
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);
    // 只构建当前页签内容，切页时需要重建
    _tabController.addListener(_onTabIndexChanged);
    // 上下方向键统一由面板自己接管（见 _onVerticalKey）
    HardwareKeyboard.instance.addHandler(_onVerticalKey);
    // 安卓端：开始采样剪贴板（粘贴按钮弹出历史供选择）
    if (_showPasteButton) _ClipHistory.ensureWatching();
  }

  @override
  void dispose() {
    _settingsOwner?.settingsNotifier.removeListener(_onSettingsChanged);
    HardwareKeyboard.instance.removeHandler(_onVerticalKey);
    _tabController.removeListener(_onTabIndexChanged);
    _navFocus.dispose();
    _panelFocusNode.dispose();
    _tabController.dispose();
    super.dispose();
  }

  int _lastTabIndex = 0;

  void _onTabIndexChanged() {
    if (_tabController.index == _lastTabIndex) return;
    _lastTabIndex = _tabController.index;
    if (mounted) setState(() {});
  }

  /// 当前页签内容（只构建选中的那一页，避免隐藏页的控件进入焦点遍历）
  Widget _tabPage(int index) {
    switch (index) {
      case 1:
        return _RadioSourcesTab();
      case 2:
        return _EpgTab();
      case 3:
        return _PlayerSettingsTab();
      case 4:
        return _SystemSettingsTab();
      case 5:
        return _HelpTab();
      default:
        return _PlaylistTab();
    }
  }

  /// 上下键改为在设置内容里纵向移动焦点。
  ///
  /// 不使用几何方向计算（focusInDirection）也不依赖 WidgetOrder 遍历：
  /// 直接取「面板根节点下所有可聚焦节点」的树顺序（即界面自上而下的顺序），
  /// 上一格/下一格走一步。这样不会隔行跳、也不会穿到播放页其它面板。
  /// 到最上面落到页签栏，页签栏上用左右键切页。
  bool _onVerticalKey(KeyEvent event) {
    if (!widget.isOpen) return false;
    // 设置里弹出对话框（编辑源、二维码等）时放行：焦点属于对话框，
    // 不能把焦点抢回设置面板
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    return _handleVertical(event);
  }

  /// 面板根焦点上的按键：与上面的全局处理器共用同一套逻辑，
  /// 保证焦点在面板内时按键一定先在这里被吃掉
  KeyEventResult _onPanelKeyEvent(FocusNode node, KeyEvent event) =>
      _handleVertical(event)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;

  bool _handleVertical(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    final key = event.logicalKey;
    final isUp = key == LogicalKeyboardKey.arrowUp;
    if (!isUp && key != LogicalKeyboardKey.arrowDown) return false;

    // 焦点在输入框内时放行：输入法（尤其是中文）用上下键选候选词，
    // 面板不能在这里抢焦点切控件——否则选词过程被中断，老系统
    // （Win10 1607）上还会出现输入框无响应（AppHangB1）
    final focusCtx = FocusManager.instance.primaryFocus?.context;
    if (focusCtx != null &&
        focusCtx.findAncestorWidgetOfExactType<EditableText>() != null) {
      return false;
    }

    // 面板内所有可聚焦节点的树顺序（页签栏在最前，内容自上而下）
    final stops = <FocusNode>[];
    for (final n in _panelFocusNode.traversalDescendants) {
      if (n.canRequestFocus && n.context != null) stops.add(n);
    }
    if (stops.isEmpty) return false;

    final focus = FocusManager.instance.primaryFocus;
    final idx = stops.indexWhere((n) => n == focus || n.hasFocus);
    if (idx < 0) {
      // 焦点还停在面板外（刚打开时）：从页签栏进入
      _navFocus.requestFocus();
      return true;
    }
    final target = idx + (isUp ? -1 : 1);
    if (target < 0 || target >= stops.length) {
      // 已到顶/到底：吞掉按键，停在原处
      return true;
    }
    stops[target].requestFocus();
    _scrollFocusedIntoView();
    return true;
  }

  /// 把当前焦点滚到可视区（设置内容是可滚动的长列表）。
  /// 焦点变更在微任务里生效，下一帧再取 primaryFocus。
  /// 从分类栏进入内容区：聚焦右栏第一个可聚焦控件
  void _focusFirstContent() {
    for (final n in _panelFocusNode.traversalDescendants) {
      if (n == _navFocus) continue;
      if (n.canRequestFocus && n.context != null) {
        n.requestFocus();
        _scrollFocusedIntoView();
        return;
      }
    }
  }

  void _scrollFocusedIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = FocusManager.instance.primaryFocus?.context;
      if (target == null || !target.mounted) return;
      Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 120),
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }


  @override
  Widget build(BuildContext context) {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOutCubic,
      bottom: widget.isOpen ? 0 : -MediaQuery.of(context).size.height,
      left: 0,
      right: 0,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: widget.isOpen ? 1.0 : 0.0,
        child: ScaledPanel(
          alignment: Alignment.bottomCenter,
          scale: panelScaleOf(context),
          // 限宽居中：设置面板不再通栏铺满，宽屏下保持 760 逻辑像素以内
          child: Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Material(
            color: AppColors.overlay,
            elevation: 28,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              side: BorderSide(color: AppColors.stroke),
            ),
            clipBehavior: Clip.antiAlias,
            child: SafeArea(
              top: false,
              child: Builder(builder: (context) {
                // 横屏手机等矮屏（高度<500）时面板几乎占满全高，避免太短无法操作
                final screenH = MediaQuery.of(context).size.height;
                return SizedBox(
                  key: _panelKey,
                  height: screenH * (screenH < 500 ? 0.95 : 0.7),
                  // 焦点遍历圈定在设置面板内（按控件树顺序上下走）：
                  // 否则方向键会穿到播放页底部面板的按钮上
                  child: FocusTraversalGroup(
                    policy: WidgetOrderTraversalPolicy(),
                    child: Focus(
                      focusNode: _panelFocusNode,
                      onKeyEvent: _onPanelKeyEvent,
                      child: Column(
                    children: [
                    // 顶部拖拽条 + 标题
                    Container(
                      padding:
                          const EdgeInsets.only(top: 10, bottom: 8),
                      child: Column(
                        children: [
                          Container(
                            width: 40,
                            height: 4,
                            decoration: BoxDecoration(
                              color: Colors.white30,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              const SizedBox(width: 16),
                              const Text(
                                '设置',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const Spacer(),
                              // 关闭按钮只给鼠标用（遥控器用 Esc 关闭），
                              // 不参与焦点遍历，保证内容区往上走落到页签栏
                              ExcludeFocus(
                                child: IconButton(
                                  icon: const Icon(Icons.close,
                                      color: Colors.white70),
                                  onPressed: widget.onClose,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const Divider(color: AppColors.divider, height: 1),
                    // 双栏设置中心（方案 4.1）：宽屏 = 左栏分类 + 右栏内容；
                    // 手机窄屏 = 左栏折成顶部横滑胶囊，其余不变
                    Expanded(
                      child: LayoutBuilder(builder: (context, box) {
                        final narrow = box.maxWidth < 620;
                        final nav = _SettingsNav(
                          index: _tabController.index,
                          axis: narrow ? Axis.horizontal : Axis.vertical,
                          focusNode: _navFocus,
                          onChanged: (i) {
                            if (i == _tabController.index) return;
                            _tabController.index = i;
                          },
                          onEnterContent: _focusFirstContent,
                        );
                        final content = _tabPage(_tabController.index);
                        if (narrow) {
                          return Column(
                            children: [
                              nav,
                              const Divider(color: AppColors.divider, height: 1),
                              Expanded(child: content),
                            ],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            nav,
                            const VerticalDivider(
                                width: 1, color: AppColors.divider),
                            Expanded(child: content),
                          ],
                        );
                      }),
                    ),
                  ],
                      ),
                    ),
                  ),
                );
              }),
            ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 设置中心左侧分类栏。
///
/// 宽屏竖排在左（图标 + 文字，选中项高亮胶囊），手机窄屏折成顶部
/// 横滑胶囊。整栏只占一个焦点停靠点：上下（窄屏左右）改分类，
/// 反方向键进入内容区——比让 5 个分类各自参与焦点遍历更好预测，
/// 内容区上下移动也不会被分类项打断。
class _SettingsNav extends StatelessWidget {
  const _SettingsNav({
    required this.index,
    required this.axis,
    required this.focusNode,
    required this.onChanged,
    required this.onEnterContent,
  });

  final int index;
  final Axis axis;
  final FocusNode focusNode;
  final ValueChanged<int> onChanged;
  final VoidCallback onEnterContent;

  static const List<(IconData, String)> _items = [
    (Icons.playlist_play, '直播源'),
    (Icons.podcasts, '在线电台'),
    (Icons.calendar_view_week, 'EPG'),
    (Icons.tune, '播放器'),
    (Icons.settings_suggest, '系统'),
    (Icons.help_outline, '说明'),
  ];

  bool get _vertical => axis == Axis.vertical;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = event.logicalKey;
    final prev = _vertical
        ? LogicalKeyboardKey.arrowUp
        : LogicalKeyboardKey.arrowLeft;
    final next = _vertical
        ? LogicalKeyboardKey.arrowDown
        : LogicalKeyboardKey.arrowRight;
    final enter = _vertical
        ? LogicalKeyboardKey.arrowRight
        : LogicalKeyboardKey.arrowDown;

    if (k == prev) {
      if (index > 0) onChanged(index - 1);
      return KeyEventResult.handled;
    }
    // 宽屏左栏在最左侧：向左没有去处，吞掉，避免焦点穿出设置面板
    if (_vertical && k == LogicalKeyboardKey.arrowLeft) {
      return KeyEventResult.handled;
    }
    if (k == next) {
      if (index < _items.length - 1) onChanged(index + 1);
      return KeyEventResult.handled;
    }
    if (k == enter ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.gameButtonA ||
        k == LogicalKeyboardKey.space) {
      onEnterContent();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final list = _vertical
        ? ListView.builder(
            padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
            itemCount: _items.length,
            itemBuilder: (context, i) => _item(i, vertical: true),
          )
        : SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                for (int i = 0; i < _items.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  _item(i, vertical: false),
                ],
              ],
            ),
          );

    return Focus(
      focusNode: focusNode,
      onKeyEvent: _onKey,
      child: ListenableBuilder(
        listenable: focusNode,
        builder: (context, child) => Container(
          width: _vertical ? 156 : null,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.18),
            // 焦点在分类栏时给外框：遥控器用户能看清焦点上来了，
            // 此时用上下（或窄屏左右）切分类
            border: focusNode.hasFocus
                ? Border.all(color: Colors.white70, width: 1)
                : null,
          ),
          child: child,
        ),
        child: list,
      ),
    );
  }

  Widget _item(int i, {required bool vertical}) {
    final selected = i == index;
    final (icon, label) = _items[i];
    return Padding(
      padding: EdgeInsets.only(bottom: vertical ? 4 : 0),
      child: Material(
        color: selected
            ? AppColors.accent.withValues(alpha: 0.18)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => onChanged(i),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: vertical ? 12 : 14,
              vertical: vertical ? 11 : 8,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected ? AppColors.accent : Colors.transparent,
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: selected ? AppColors.accent : Colors.white54,
                ),
                if (vertical) const SizedBox(width: 10) else const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: selected ? Colors.white : Colors.white60,
                    fontSize: vertical ? 14 : 13,
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ==================== 播放列表管理标签页 ====================

class _PlaylistTab extends StatefulWidget {
  @override
  State<_PlaylistTab> createState() => _PlaylistTabState();
}

class _PlaylistTabState extends State<_PlaylistTab> {
  final _nameController = TextEditingController();
  final _urlController = TextEditingController();
  final _groupFilterController = TextEditingController();
  PlaylistSourceType _type = PlaylistSourceType.url;
  bool _isLoading = false;

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _groupFilterController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _pickLocalFile() async {
    // file_picker 12+ 新 API：FilePicker.pickFile 直接返回 PlatformFile?
    // 放开所有文件类型：直播源后缀五花八门（.m3u/.m3u8/.txt/.nzk/
    // .conf/.list/.php 甚至无后缀），加载时按内容自动识别格式
    final file = await _pickLocalFileWithTopmostFix();
    if (file?.path != null) {
      setState(() {
        _urlController.text = file!.path!;
        _type = PlaylistSourceType.local;
      });
    }
  }

  Future<void> _addPlaylist() async {
    final name = _nameController.text.trim();
    final url = _urlController.text.trim();
    if (name.isEmpty || url.isEmpty) {
      OsdBus.show('请填写名称和地址', icon: Icons.warning_amber_rounded);
      return;
    }
    setState(() => _isLoading = true);
    // 格式存 unknown：加载时按文件/响应【内容】嗅探，后缀不可靠
    // （.php 可能是 M3U 也可能是 TVBox TXT，.nzk 实际是 TXT）
    const format = PlaylistFormat.unknown;
    final source = PlaylistSource(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      url: url,
      type: _type,
      format: format,
      addedAt: DateTime.now(),
      groupFilter: _groupFilterController.text.trim(),
    );
    await context.read<PlayerController>().addPlaylist(source);
    _nameController.clear();
    _urlController.clear();
    _groupFilterController.clear();
    setState(() => _isLoading = false);
  }

  /// 编辑已有播放列表（名称/地址/类型）
  Future<void> _editPlaylist(PlaylistSource source) async {
    final nameCtl = TextEditingController(text: source.name);
    final urlCtl = TextEditingController(text: source.url);
    final filterCtl = TextEditingController(text: source.groupFilter);
    var type = source.type;
    if (!mounted) return;
    final result = await showDialog<PlaylistSource>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: const Text('编辑播放列表'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SegmentedButton<PlaylistSourceType>(
                  segments: const [
                    ButtonSegment(
                        value: PlaylistSourceType.url, label: Text('网络地址')),
                    ButtonSegment(
                        value: PlaylistSourceType.local, label: Text('本地文件')),
                  ],
                  selected: {type},
                  onSelectionChanged: (s) => setDialog(() => type = s.first),
                ),
                const SizedBox(height: 10),
                _ImeSafeTextField(
                  controller: nameCtl,
                  style: const TextStyle(color: Colors.white),
                  decoration: _inputDecoration('列表名称'),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _ImeSafeTextField(
                        controller: urlCtl,
                        style: const TextStyle(color: Colors.white),
                        decoration: _inputDecoration(
                            type == PlaylistSourceType.url ? '直播源地址' : '本地文件路径',
                            urlCtl),
                      ),
                    ),
                      if (type == PlaylistSourceType.local)
                        IconButton(
                          icon: const Icon(Icons.folder_open,
                              color: Colors.blueAccent),
                          onPressed: () async {
                            final f =
                                await _pickLocalFileWithTopmostFix();
                            if (f?.path != null) urlCtl.text = f!.path!;
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _ImeSafeTextField(
                    controller: filterCtl,
                    style: const TextStyle(color: Colors.white),
                    decoration: _inputDecoration(
                        '分组过滤（可选）：只导入命中的分组，逗号分隔'),
                  ),
                ],
              ),
            ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () {
                final name = nameCtl.text.trim();
                final url = urlCtl.text.trim();
                if (name.isEmpty || url.isEmpty) return;
                Navigator.pop(
                  ctx,
                  source.copyWith(
                    name: name,
                    url: url,
                    type: type,
                    groupFilter: filterCtl.text.trim(),
                  ),
                );
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (result != null && mounted) {
      await context.read<PlayerController>().editPlaylist(result);
    }
  }

  /// 复制播放列表地址到剪贴板
  Future<void> _copyPlaylist(PlaylistSource p) async {
    await Clipboard.setData(ClipboardData(text: p.url));
    if (!mounted) return;
    OsdBus.show('地址已复制', icon: Icons.copy);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerController>(
      builder: (context, controller, _) {
        // 电台源（内置精选 / 我的电台）整页迁到「在线电台」页签，
        // 这里只管电视直播源——加源、选源、编辑、刷新、删除
        final playlists = controller.sourceManager.playlists;
        final tvPlaylists = playlists
            .where((p) => !_PlaylistTabState.isRadioPlaylist(p))
            .toList();
        // 整页 ListView：表单+列表一起滚动，横屏矮屏也不会溢出
        return ListView(
          padding: const EdgeInsets.only(bottom: 12),
          children: [
            // 添加表单
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: SegmentedButton<PlaylistSourceType>(
                          segments: const [
                            ButtonSegment(
                                value: PlaylistSourceType.url,
                                label: Text('网络地址')),
                            ButtonSegment(
                                value: PlaylistSourceType.local,
                                label: Text('本地文件')),
                          ],
                          selected: {_type},
                          onSelectionChanged: (s) =>
                              setState(() => _type = s.first),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _ImeSafeTextField(
                    controller: _nameController,
                    style: const TextStyle(color: Colors.white),
                    decoration: _inputDecoration('列表名称（如：我的电视）'),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _ImeSafeTextField(
                          controller: _urlController,
                          style: const TextStyle(color: Colors.white),
                          decoration: _inputDecoration(
                              _type == PlaylistSourceType.url
                                  ? '直播源地址（M3U / TVBox TXT / PHP 等，自动识别）'
                                  : '本地文件路径（任意类型，自动识别）',
                              _urlController),
                        ),
                      ),
                      if (_type == PlaylistSourceType.local)
                        IconButton(
                          icon: const Icon(Icons.folder_open,
                              color: Colors.blueAccent),
                          onPressed: _pickLocalFile,
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _ImeSafeTextField(
                    controller: _groupFilterController,
                    style: const TextStyle(color: Colors.white),
                    decoration: _inputDecoration(
                        '分组过滤（可选）：只导入命中的分组，逗号分隔，如 央视,卫视'),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _isLoading ? null : _addPlaylist,
                      icon: const Icon(Icons.add),
                      label: Text(_isLoading ? '添加中...' : '添加播放列表'),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12),
            // 播放列表（仅电视直播源；电台源在「在线电台」页签）
            if (tvPlaylists.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Text('暂无直播源，请添加',
                      style: TextStyle(color: Colors.white54)),
                ),
              )
            else
              ...List.generate(tvPlaylists.length, (index) {
                final p = tvPlaylists[index];
                final isCurrent =
                    controller.sourceManager.currentPlaylistId == p.id;
                return _SourceRow(
                  // 内置源在标题上带「内置」后缀，副标题说明内容范围，
                  // 让用户一眼看出这不是自己加的、删了还能恢复
                  title: p.isBuiltin ? '${p.name} · 内置' : p.name,
                  subtitle: p.url,
                  icon: p.type == PlaylistSourceType.url
                      ? Icons.cloud
                      : Icons.folder,
                  isCurrent: isCurrent,
                  // 行上按 OK = 选定该播放列表；左右键进入行尾按钮
                  onSelect: isCurrent
                      ? null
                      : () => controller.selectPlaylist(p.id),
                  actions: [
                    // 内置源/我的电台地址都不是可编辑的字符串：不给编辑入口
                    if (!p.isBuiltin &&
                        p.type != PlaylistSourceType.radioLibrary)
                      _RowAction(Icons.edit, Colors.lightBlueAccent, '编辑',
                          () => _editPlaylist(p)),
                    if (!p.isBuiltin &&
                        p.type != PlaylistSourceType.radioLibrary)
                      _RowAction(Icons.copy, Colors.white60, '复制名称和地址',
                          () => _copyPlaylist(p)),
                    _RowAction(Icons.refresh, Colors.amber, '刷新',
                        () => controller.refreshChannels()),
                    _RowAction(Icons.delete, Colors.redAccent, '删除',
                        () => controller.removePlaylist(p.id)),
                  ],
                );
              }),
          ],
        );
      },
    );
  }

  /// 电台类播放列表：内置精选 + 我的电台（RadioLibrary）
  static bool isRadioPlaylist(PlaylistSource p) =>
      p.id == PlaylistSource.builtinRadioId ||
      p.id == PlaylistSource.radioLibraryId;
}

/// 在线电台页签：内置精选 / 我的电台 管理 + Radio Browser 搜索入口。
/// 从「节目源」里拆出来——直播源与电台是两套心智，混在一页互相干扰
class _RadioSourcesTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
  /// 管理区块统一收进折叠条：收起时不构建内容
  Widget _manageSection(
      {required IconData icon, required String title, required Widget child}) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        leading: Icon(icon, size: 18, color: Colors.white54),
        title: Text(title,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold)),
        iconColor: Colors.white54,
        collapsedIconColor: Colors.white54,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.only(bottom: 8),
        children: [child],
      ),
    );
  }

    return Consumer<PlayerController>(
      builder: (context, controller, _) {
        final playlists = controller.sourceManager.playlists;
        final radioPlaylists = playlists
            .where(_PlaylistTabState.isRadioPlaylist)
            .toList();
        return ListView(
          padding: const EdgeInsets.only(bottom: 12),
          children: [
            // 搜索入口：搜到哪台就加到「我的电台」（方案 12.2 第 3 条）
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Row(
                children: [
                  const Icon(Icons.podcasts, size: 18, color: Colors.white54),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '内置精选不可删（可整源移除）· 搜到的台进「我的电台」可随时删',
                      style: TextStyle(color: Colors.white54, fontSize: 12.5),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => RadioSearchDialog.show(context),
                    icon: const Icon(Icons.travel_explore, size: 18),
                    label: const Text('在线电台'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: AppColors.stroke),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12),
            if (radioPlaylists.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Text('暂无电台源，可用右上角「在线电台」搜索添加',
                      style: TextStyle(color: Colors.white54)),
                ),
              )
            else
              ...List.generate(radioPlaylists.length, (index) {
                final p = radioPlaylists[index];
                final isCurrent =
                    controller.sourceManager.currentPlaylistId == p.id;
                final isLibrary =
                    p.id == PlaylistSource.radioLibraryId;
                return _SourceRow(
                  title: p.isBuiltin ? '${p.name} · 内置' : p.name,
                  subtitle: p.isBuiltin
                      ? '出厂自带 · 电视伴音 / 央广 / 省市台 / 音乐 / 故事 · '
                          '单台不可删，只能整源移除（之后可恢复）'
                      : '在线目录加入的电台 · 共 ${RadioLibrary.count} 个 · '
                          '单个移除/清空都在「在线电台」搜索页里',
                  icon: p.isBuiltin ? Icons.radio : Icons.podcasts,
                  isCurrent: isCurrent,
                  onSelect:
                      isCurrent ? null : () => controller.selectPlaylist(p.id),
                  actions: [
                    _RowAction(Icons.refresh, Colors.amber, '刷新',
                        () => controller.refreshChannels()),
                    _RowAction(Icons.delete, Colors.redAccent,
                        isLibrary ? '清空我的电台' : '整源移除',
                        () => controller.removePlaylist(p.id)),
                  ],
                );
              }),
            // 内置电台被删过：给一条恢复入口（删了不是永久丢）
            if (controller.builtinRadioRemoved)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _SourceRow(
                  title: '恢复内置电台精选',
                  subtitle: '重新加入出厂自带的电台源（60 个台）',
                  icon: Icons.restore,
                  isCurrent: false,
                  onSelect: () => controller.restoreBuiltinRadio(),
                  actions: const [],
                ),
              ),
            // ===== 方案 12.3 第一档：场景收藏 / 电台别名 / 录音库 =====
            // 默认收起：展开才构建列表，切到本页签首屏只画三行标题——
            // 以前这三块常驻展开，几十行控件 + 文件 stat 全量构建，
            // 是「切页签卡一两秒」的大头
            _manageSection(
                icon: Icons.star,
                title: '收藏场景管理',
                child: _SceneManageSection()),
            _manageSection(
                icon: Icons.label_outline,
                title: '电台别名',
                child: _AliasSection()),
            _manageSection(
                icon: Icons.graphic_eq,
                title: '录音库',
                child: _RecordingsSection()),
          ],
        );
      },
    );
  }
}

// ==================== 场景收藏管理（方案 12.3） ====================

/// 收藏从单列表升级为多场景分组：列表抽屉里每个场景一列，
/// 进入某场景后收藏动作就落到该场景。这里管场景的增删改名。
class _SceneManageSection extends StatefulWidget {
  const _SceneManageSection();

  @override
  State<_SceneManageSection> createState() => _SceneManageSectionState();
}

class _SceneManageSectionState extends State<_SceneManageSection> {
  InputDecoration _deco(String hint) => InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white24, fontSize: 13),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Colors.white12),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Colors.white12),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      );

  Future<void> _newScene() async {
    final ctl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建收藏场景'),
        content: _ImeSafeTextField(
          controller: ctl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: _deco('场景名，如：新闻 / 音乐 / 戏曲'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
              child: const Text('创建')),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    await context.read<PlayerController>().createScene(name);
    OsdBus.show('已创建场景〈$name〉，到列表抽屉进入它再收藏', icon: Icons.star);
  }

  Future<void> _renameScene(String oldName) async {
    final ctl = TextEditingController(text: oldName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('重命名场景：$oldName'),
        content: _ImeSafeTextField(
          controller: ctl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: _deco('新场景名'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == oldName || !mounted) return;
    await context.read<PlayerController>().renameScene(oldName, name);
  }

  Future<void> _deleteScene(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除场景〈$name〉？'),
        content: const Text('组内收藏会一并清除，频道本身不受影响。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<PlayerController>().deleteScene(name);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerController>(builder: (context, controller, _) {
      final scenes = controller.sceneNames;
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.collections_bookmark,
                    size: 18, color: Colors.white54),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('场景收藏',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.bold)),
                ),
                OutlinedButton.icon(
                  onPressed: _newScene,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('新建场景'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: AppColors.stroke),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              '列表抽屉里每个场景是一列；进入某场景后，收藏（星标/长按 OK）就落到该场景',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
            const SizedBox(height: 8),
            for (final scene in scenes)
              Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: scene == controller.activeSceneName
                      ? Colors.amber.withValues(alpha: 0.10)
                      : Colors.white.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(8),
                  border: scene == controller.activeSceneName
                      ? Border.all(
                          color: Colors.amber.withValues(alpha: 0.45))
                      : null,
                ),
                child: Row(
                  children: [
                    Icon(
                      scene == controller.activeSceneName
                          ? Icons.star
                          : Icons.star_outline,
                      size: 15,
                      color: Colors.amber,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: scene == controller.activeSceneName
                            ? null
                            : () {
                                controller.setActiveScene(scene);
                                OsdBus.show('收藏落点已切到〈$scene〉',
                                    icon: Icons.star);
                                setState(() {});
                              },
                        child: Text(
                          '$scene · ${SceneFavorites.countIn(scene)} 个'
                          '${scene == controller.activeSceneName ? ' · 收藏落点' : ''}',
                          style: const TextStyle(
                              color: Color(0xDDFFFFFF), fontSize: 13),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '重命名',
                      icon: const Icon(Icons.edit_outlined,
                          size: 17, color: Colors.white54),
                      onPressed: () => _renameScene(scene),
                    ),
                    // 至少保留一个场景
                    if (scenes.length > 1)
                      IconButton(
                        tooltip: '删除场景',
                        icon: const Icon(Icons.delete_outline,
                            size: 17, color: Colors.redAccent),
                        onPressed: () => _deleteScene(scene),
                      ),
                  ],
                ),
              ),
          ],
        ),
      );
    });
  }
}

// ==================== 电台别名（方案 12.3） ====================

/// 个性化显示名：只改显示不动数据，列表/播放页/面板/通知栏统一生效。
class _AliasSection extends StatefulWidget {
  const _AliasSection();

  @override
  State<_AliasSection> createState() => _AliasSectionState();
}

class _AliasSectionState extends State<_AliasSection> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  InputDecoration _deco(String hint) => InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white24, fontSize: 13),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Colors.white12),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Colors.white12),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      );

  Future<void> _editAlias(Channel ch) async {
    final controller = context.read<PlayerController>();
    final ctl =
        TextEditingController(text: ChannelAlias.aliasOf(ch.id) ?? '');
    final alias = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('别名：${ch.name}'),
        content: _ImeSafeTextField(
          controller: ctl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: _deco('显示名（清空 = 恢复原名）'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
    if (alias == null || !mounted) return;
    await controller.setChannelAlias(ch.id, alias);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerController>(builder: (context, controller, _) {
      // 电台域全量频道：内置精选 + 我的电台 + 当前源里的电台
      final channels = <Channel>[];
      final seen = <String>{};
      for (final cat in controller.radioCategories) {
        for (final ch in cat.channels) {
          if (seen.add(ch.id)) channels.add(ch);
        }
      }
      channels.sort((a, b) => a.name.compareTo(b.name));
      final q = _query.trim().toLowerCase();
      final filtered = q.isEmpty
          ? channels
          : channels
              .where((ch) =>
                  ch.name.toLowerCase().contains(q) ||
                  (ChannelAlias.aliasOf(ch.id) ?? '').toLowerCase().contains(q))
              .toList();
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.label_outline, size: 18, color: Colors.white54),
                SizedBox(width: 8),
                Expanded(
                  child: Text('电台别名',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              '给台起自己的名字，只改显示，随时恢复',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
            const SizedBox(height: 8),
            _ImeSafeTextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _query = v),
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: _deco('搜索台名 / 别名'),
            ),
            const SizedBox(height: 6),
            ...filtered.take(50).map((ch) {
              final alias = ChannelAlias.aliasOf(ch.id);
              return Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            alias == null ? ch.name : '$alias（原：${ch.name}）',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: alias == null
                                  ? const Color(0xDDFFFFFF)
                                  : Colors.amberAccent,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: alias == null ? '设置别名' : '修改别名',
                      icon: Icon(Icons.edit_outlined,
                          size: 17,
                          color: alias == null
                              ? Colors.white54
                              : Colors.amberAccent),
                      onPressed: () => _editAlias(ch),
                    ),
                  ],
                ),
              );
            }),
            if (filtered.length > 50)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('只显示前 50 个，输入关键字缩小范围',
                    style: TextStyle(color: Colors.white24, fontSize: 12)),
              ),
          ],
        ),
      );
    });
  }
}

// ==================== 录音库（方案 12.3） ====================

/// 边听边录的录音管理：列出/播放/删除录音文件。
class _RecordingsSection extends StatefulWidget {
  const _RecordingsSection();

  @override
  State<_RecordingsSection> createState() => _RecordingsSectionState();
}

class _RecordingsSectionState extends State<_RecordingsSection> {
  List<File> _files = const [];

  /// 文件元数据缓存：一次批量 stat。以前每个文件挂一个 FutureBuilder，
  /// 每次面板重建（拨开关/切页签/播放状态变化）都重发一轮 stat IO，
  /// 录多了之后就是「切到这页签卡一两秒」的主因之一
  final Map<String, FileStat?> _statCache = {};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final files = await RadioRecorder.list();
    for (final f in files) {
      if (_statCache.containsKey(f.path)) continue;
      try {
        _statCache[f.path] = await f.stat();
      } catch (_) {
        _statCache[f.path] = null;
      }
    }
    // 只留现存文件的缓存
    _statCache.removeWhere((k, _) => files.every((f) => f.path != k));
    if (mounted) setState(() => _files = files);
  }

  Future<void> _play(File f) async {
    final controller = context.read<PlayerController>();
    final name = f.path.split(Platform.pathSeparator).last;
    await controller.playChannel(Channel(
      id: 'recording:${f.path}',
      name: name,
      streamUrls: [f.path],
      categoryId: '::recordings::',
      channelType: ChannelType.radio,
    ));
    OsdBus.show('正在播放录音：$name', icon: Icons.graphic_eq);
  }

  Future<void> _delete(File f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除录音？'),
        content: Text(f.path.split(Platform.pathSeparator).last),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (ok != true) return;
    await RadioRecorder.delete(f.path);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerController>(builder: (context, controller, _) {
      final recording = controller.isRadioRecording;
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.graphic_eq, size: 18, color: Colors.white54),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('录音库',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.bold)),
                ),
                if (!kIsWeb &&
                    (defaultTargetPlatform == TargetPlatform.windows ||
                        defaultTargetPlatform == TargetPlatform.linux ||
                        defaultTargetPlatform == TargetPlatform.macOS))
                  OutlinedButton.icon(
                    onPressed: () => RadioRecorder.openFolder(),
                    icon: const Icon(Icons.folder_open, size: 16),
                    label: const Text('打开文件夹'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: AppColors.stroke),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              '播放电台时点底部面板「录音」即边听边录（原始流直存，不转码）',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
            const SizedBox(height: 8),
            if (recording)
              Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: Colors.redAccent.withValues(alpha: 0.4)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.fiber_manual_record,
                        size: 14, color: Colors.redAccent),
                    SizedBox(width: 8),
                    Text('正在录音…（底部面板可停止）',
                        style: TextStyle(color: Color(0xDDFFFFFF), fontSize: 13)),
                  ],
                ),
              ),
            if (_files.isEmpty && !recording)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('还没有录音',
                    style: TextStyle(color: Colors.white24, fontSize: 12.5)),
              )
            else
              ..._files.map((f) {
                final name = f.path.split(Platform.pathSeparator).last;
                final snapData = _statCache[f.path];
                final size = snapData?.size ?? 0;
                final modified = snapData?.modified;
                final when = modified == null
                    ? ''
                    : '${modified.year}-${modified.month.toString().padLeft(2, '0')}-${modified.day.toString().padLeft(2, '0')} '
                        '${modified.hour.toString().padLeft(2, '0')}:${modified.minute.toString().padLeft(2, '0')}';
                return Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Color(0xDDFFFFFF), fontSize: 13)),
                            Text(
                              '${RadioRecorder.humanSize(size)}  $when',
                              style: const TextStyle(
                                  color: Colors.white38, fontSize: 11.5),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: '播放',
                        icon: const Icon(Icons.play_circle_outline,
                            size: 19, color: Colors.blueAccent),
                        onPressed: () => _play(f),
                      ),
                      IconButton(
                        tooltip: '分享',
                        icon: const Icon(Icons.ios_share,
                            size: 17, color: Color(0xCCFFFFFF)),
                        onPressed: () => RecordingShare.share(f.path, name),
                      ),
                      IconButton(
                        tooltip: '删除',
                        icon: const Icon(Icons.delete_outline,
                            size: 17, color: Colors.redAccent),
                        onPressed: () => _delete(f),
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      );
    });
  }
}

// ==================== EPG 管理标签页 ====================

class _EpgTab extends StatefulWidget {
  @override
  State<_EpgTab> createState() => _EpgTabState();
}

class _EpgTabState extends State<_EpgTab> {
  final _nameController = TextEditingController();
  final _urlController = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _addEpg() async {
    final name = _nameController.text.trim();
    final url = _urlController.text.trim();
    if (name.isEmpty || url.isEmpty) {
      OsdBus.show('请填写名称和地址', icon: Icons.warning_amber_rounded);
      return;
    }
    setState(() => _isLoading = true);
    final source = EpgSource(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      url: url,
      addedAt: DateTime.now(),
    );
    await context.read<PlayerController>().addEpg(source);
    _nameController.clear();
    _urlController.clear();
    setState(() => _isLoading = false);
  }

  /// 编辑已有 EPG 源（名称/地址）
  Future<void> _editEpg(EpgSource source) async {
    final nameCtl = TextEditingController(text: source.name);
    final urlCtl = TextEditingController(text: source.url);
    if (!mounted) return;
    final result = await showDialog<EpgSource>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑 EPG'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ImeSafeTextField(
              controller: nameCtl,
              style: const TextStyle(color: Colors.white),
              decoration: _inputDecoration('EPG 名称'),
            ),
            const SizedBox(height: 8),
            _ImeSafeTextField(
              controller: urlCtl,
              style: const TextStyle(color: Colors.white),
              decoration: _inputDecoration('XMLTV EPG 地址 URL', urlCtl),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              final name = nameCtl.text.trim();
              final url = urlCtl.text.trim();
              if (name.isEmpty || url.isEmpty) return;
              Navigator.pop(ctx, source.copyWith(name: name, url: url));
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result != null && mounted) {
      await context.read<PlayerController>().editEpg(result);
    }
  }

  /// 复制 EPG 地址到剪贴板
  Future<void> _copyEpg(EpgSource e) async {
    await Clipboard.setData(ClipboardData(text: e.url));
    if (!mounted) return;
    OsdBus.show('地址已复制', icon: Icons.copy);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerController>(
      builder: (context, controller, _) {
        final epgs = controller.sourceManager.epgs;
        // 整页 ListView：表单+列表一起滚动，横屏矮屏也不会溢出
        return ListView(
          padding: const EdgeInsets.only(bottom: 12),
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  _ImeSafeTextField(
                    controller: _nameController,
                    style: const TextStyle(color: Colors.white),
                    decoration: _inputDecoration('EPG 名称（如：央视节目单）'),
                  ),
                  const SizedBox(height: 8),
                  _ImeSafeTextField(
                    controller: _urlController,
                    style: const TextStyle(color: Colors.white),
                    decoration:
                        _inputDecoration('XMLTV EPG 地址 URL', _urlController),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _isLoading ? null : _addEpg,
                      icon: const Icon(Icons.add),
                      label: Text(_isLoading ? '添加中...' : '添加 EPG'),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12),
            if (epgs.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Text('暂无 EPG 源，请添加',
                      style: TextStyle(color: Colors.white54)),
                ),
              )
            else
              ...List.generate(epgs.length, (index) {
                final e = epgs[index];
                final isCurrent =
                    controller.sourceManager.currentEpgId == e.id;
                return _SourceRow(
                  title: e.name,
                  subtitle: e.url,
                  icon: Icons.menu_book,
                  isCurrent: isCurrent,
                  onSelect:
                      isCurrent ? null : () => controller.selectEpg(e.id),
                  actions: [
                    _RowAction(Icons.edit, Colors.lightBlueAccent, '编辑',
                        () => _editEpg(e)),
                    _RowAction(Icons.copy, Colors.white60, '复制名称和地址',
                        () => _copyEpg(e)),
                    _RowAction(Icons.refresh, Colors.amber, '刷新',
                        () => controller.refreshEpg()),
                    _RowAction(Icons.delete, Colors.redAccent, '删除',
                        () => controller.removeEpg(e.id)),
                  ],
                );
              }),
          ],
        );
      },
    );
  }
}

// ==================== 播放器设置标签页 ====================

class _PlayerSettingsTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerController>(
      builder: (context, controller, _) {
        final s = controller.settings;
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            _buildQualitySelector(controller),
            // 声音实验室（方案 12.3 第二档）：mpv lavfi 音频滤镜，
            // 内置播放器全局生效（电视伴音/电台都可用；网页频道不支持）
            ListTile(
              leading: const Icon(Icons.equalizer, color: Colors.white70),
              title: const Text('声音实验室',
                  style: TextStyle(color: Colors.white, fontSize: 15)),
              subtitle: Text(
                '当前：${controller.audioPreset.isEmpty ? '标准' : _audioPresetLabelOf(controller.audioPreset)}'
                ' · 人声更清楚 / 低音更带感 / 夜间音量平稳，仅内置播放器',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right, color: Colors.white38),
              onTap: () => _showAudioPresetDialog(context, controller),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.skip_next, color: Colors.white70),
              title: const Text('自动播放下一频道',
                  style: TextStyle(color: Colors.white, fontSize: 15)),
              subtitle: const Text('当前节目结束后自动切换',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              value: s.autoPlayNext,
              onChanged: (v) => controller
                  .updateSettings(s.copyWith(autoPlayNext: v)),
              activeColor: Colors.blueAccent,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.restore, color: Colors.white70),
              title: const Text('启动时恢复上次频道',
                  style: TextStyle(color: Colors.white, fontSize: 15)),
              subtitle: const Text(
                  '关闭后启动停在「请选择频道」，不发起任何网络请求',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              value: s.resumeLastChannel,
              onChanged: (v) => controller
                  .updateSettings(s.copyWith(resumeLastChannel: v)),
              activeColor: Colors.blueAccent,
            ),
            // 换台跳过：关键词命中台名/分组名即跳过（列表里仍可见可点播）
            const _BlacklistRow(),
            _buildSlider(
              icon: Icons.touch_app,
              title: '手势灵敏度',
              value: s.gestureSensitivity,
              min: 0.5,
              max: 2.0,
              divisions: 15,
              label: '${s.gestureSensitivity.toStringAsFixed(1)}x',
              onChanged: (v) => controller
                  .updateSettings(s.copyWith(gestureSensitivity: v)),
            ),
            _buildSlider(
              icon: Icons.timer,
              title: '面板自动隐藏',
              value: s.autoHideDelay / 1000,
              min: 1.0,
              max: 10.0,
              divisions: 9,
              label: '${(s.autoHideDelay / 1000).toStringAsFixed(1)} 秒',
              onChanged: (v) => controller.updateSettings(
                  s.copyWith(autoHideDelay: (v * 1000).round())),
            ),
            _buildSlider(
              icon: Icons.swap_horiz,
              title: '切源等待时间',
              value: s.sourceTimeoutSeconds.toDouble(),
              min: 5,
              max: 30,
              divisions: 5,
              label: '${s.sourceTimeoutSeconds} 秒',
              onChanged: (v) => controller.updateSettings(
                  s.copyWith(sourceTimeoutSeconds: v.round())),
              subtitleText: '起播超过该时间未成功，自动尝试下一个源',
            ),
            // 播放缓冲：分段选择 5/10/20/30 秒（换台时由 MDK 后端应用）
            ListTile(
              leading: const Icon(Icons.slow_motion_video,
                  color: Colors.white70),
              title: const Text('播放缓冲'),
              subtitle: const Text('弱网或直播卡顿可调大，换台后生效'),
              trailing: SegmentedButton<int>(
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
                segments: const [5, 10, 20, 30]
                    .map((v) =>
                        ButtonSegment(value: v, label: Text('$v 秒')))
                    .toList(),
                selected: {s.bufferSeconds},
                onSelectionChanged: (sel) => controller.updateSettings(
                    s.copyWith(bufferSeconds: sel.first)),
              ),
            ),
            _buildUiScaleTile(context, controller, s),
            const SizedBox(height: 16),
          ],
        );
      },
    );
  }

  /// 字体缩放：自动按分辨率适配 + 手动滑块
  Widget _buildUiScaleTile(
      BuildContext context, PlayerController controller, PlayerSettings s) {
    final mq = MediaQuery.of(context);
    final physicalW = mq.size.width * mq.devicePixelRatio;
    final autoScale = (physicalW / 1920.0).clamp(1.0, 3.0);
    final scale = s.uiScaleAuto ? autoScale : s.uiScale;
    return Column(
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.screen_rotation,
              color: Colors.white70),
          title: const Text('字体大小自动适配',
              style: TextStyle(color: Colors.white, fontSize: 15)),
          subtitle: Text(
            '按屏幕分辨率自动缩放（当前屏幕：${physicalW.round()} 像素，自动 ${autoScale.toStringAsFixed(2)}x）',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          value: s.uiScaleAuto,
          onChanged: (v) =>
              controller.updateSettings(s.copyWith(uiScaleAuto: v)),
          activeColor: Colors.blueAccent,
        ),
        ListTile(
          leading: Icon(Icons.format_size,
              color: s.uiScaleAuto ? Colors.white24 : Colors.white70),
          title: Text('手动字体缩放',
              style: TextStyle(
                  color: s.uiScaleAuto ? Colors.white38 : Colors.white,
                  fontSize: 15)),
          enabled: !s.uiScaleAuto,
          subtitle: _NavSlider(
            // 自动模式下展示当前生效值但禁止拖动
            value: scale.clamp(0.8, 3.0).toDouble(),
            min: 0.8,
            max: 3.0,
            divisions: 22,
            label: '${scale.toStringAsFixed(1)}x',
            onChanged: s.uiScaleAuto
                ? null
                : (v) => controller.updateSettings(s.copyWith(uiScale: v)),
          ),
        ),
      ],
    );
  }

  static String _audioPresetLabelOf(String key) {
    switch (key) {
      case 'voice':
        return '人声增强';
      case 'bass':
        return '低音增强';
      case 'night':
        return '夜间模式';
      default:
        return '标准';
    }
  }

  Future<void> _showAudioPresetDialog(
      BuildContext context, PlayerController controller) async {
    final current = controller.audioPreset;
    final options = <(String, String, String)>[
      ('', '标准', '不加处理，原声直出'),
      ('voice', '人声增强', '新闻/口播更清楚，压轰鸣提人声'),
      ('bass', '低音增强', '音乐台更带感'),
      ('night', '夜间模式', '音量忽大忽小被抹平，睡前听不打醒'),
    ];
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('声音实验室'),
        children: [
          for (final o in options)
            RadioGroup<String>(
              groupValue: current,
              onChanged: (v) => Navigator.pop(ctx, v),
              child: RadioListTile<String>(
                value: o.$1,
                title: Text(o.$2,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 15)),
                subtitle: Text(o.$3,
                    style:
                        const TextStyle(color: Colors.white38, fontSize: 12)),
              ),
            ),
          RadioGroup<String>(
            groupValue: current,
            onChanged: (v) => Navigator.pop(ctx, v),
            child: RadioListTile<String>(
              value: 'custom',
              title: Text('自定义均衡器',
                  style: const TextStyle(color: Colors.white, fontSize: 15)),
              subtitle: Text(_eqSummary(controller.audioEqGains),
                  style: const TextStyle(color: Colors.white38, fontSize: 12)),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('仅内置播放器生效；网页频道用站点自己的播放器，不参与',
                style: TextStyle(color: Colors.white24, fontSize: 11.5)),
          ),
        ],
      ),
    );
    if (picked == null) return;
    if (picked == 'custom') {
      await controller.setAudioPreset('custom');
      if (!context.mounted) return;
      await _showEqDialog(context, controller);
      return;
    }
    await controller.setAudioPreset(picked);
  }

  /// 均衡器概要（拖到非 0 的段才显示）
  static String _eqSummary(List<double> gains) {
    final active = <String>[];
    for (var i = 0; i < gains.length && i < PlayerController.kEqBandLabels.length; i++) {
      final g = gains[i];
      if (g.abs() >= 0.05) {
        active.add('${PlayerController.kEqBandLabels[i]}'
            '${g > 0 ? '+' : ''}${g.toStringAsFixed(0)}');
      }
    }
    return active.isEmpty ? '未调整（全部直通）' : active.join('  ');
  }

  /// 自定义均衡器：10 段滑杆（31Hz~16kHz，±12dB），松手即生效
  Future<void> _showEqDialog(
      BuildContext context, PlayerController controller) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final gains = controller.audioEqGains;
          return AlertDialog(
            title: Row(
              children: [
                const Expanded(
                  child: Text('自定义均衡器（10 段）',
                      style: TextStyle(fontSize: 16)),
                ),
                TextButton(
                  onPressed: () async {
                    await controller.resetAudioEq();
                    setLocal(() {});
                  },
                  child: const Text('拉平'),
                ),
              ],
            ),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < PlayerController.kEqBands.length; i++)
                    Row(
                      children: [
                        SizedBox(
                          width: 42,
                          child: Text(
                            PlayerController.kEqBandLabels[i],
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 12),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Slider(
                            value: gains[i],
                            min: -12,
                            max: 12,
                            divisions: 24,
                            label:
                                '${gains[i] > 0 ? '+' : ''}${gains[i].toStringAsFixed(1)}',
                            onChanged: (v) async {
                              await controller.setAudioEqGain(i, v);
                              setLocal(() {});
                            },
                          ),
                        ),
                      ],
                    ),
                  const SizedBox(height: 4),
                  const Text(
                    '往上调增强该频段，往下调削弱；每档 0.5dB 一格，拖动即生效',
                    style: TextStyle(color: Colors.white24, fontSize: 11.5),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('完成'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildQualitySelector(PlayerController controller) {
    return ExpansionTile(
      leading: const Icon(Icons.hd, color: Colors.white70),
      title: const Text('视频画质',
          style: TextStyle(color: Colors.white, fontSize: 15)),
      subtitle: Text(controller.settings.preferredQuality.label,
          style: const TextStyle(color: Colors.white54, fontSize: 12)),
      iconColor: Colors.white70,
      collapsedIconColor: Colors.white70,
      children: VideoQuality.values.map((q) {
        return RadioListTile<VideoQuality>(
          value: q,
          groupValue: controller.settings.preferredQuality,
          onChanged: (v) {
            if (v != null) {
              controller.updateSettings(
                  controller.settings.copyWith(preferredQuality: v));
            }
          },
          title: Text(q.label,
              style:
                  const TextStyle(color: Colors.white70, fontSize: 14)),
          activeColor: Colors.blueAccent,
        );
      }).toList(),
    );
  }

  Widget _buildSlider({
    required IconData icon,
    required String title,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String label,
    required ValueChanged<double> onChanged,
    String? subtitleText,
  }) {
    final clamped = value.clamp(min, max);
    return ListTile(
      leading: Icon(icon, color: Colors.white70),
      title: Text(title,
          style: const TextStyle(color: Colors.white, fontSize: 15)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (subtitleText != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(subtitleText,
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 12)),
            ),
          _NavSlider(
            value: clamped.toDouble(),
            min: min,
            max: max,
            divisions: divisions,
            label: label,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

// ==================== 遥控器可用的滑块 ====================

/// 键盘/遥控器友好的滑块。
/// Flutter 自带的 Slider 会把上下方向键当成数值增减（并且它自己持有焦点，
/// 比外层更靠近焦点树），结果焦点落在滑块上就跳不出来、按上下还会改值。
/// 这里给滑块套一个自建焦点节点：内层 Slider 用 ExcludeFocus 排除出焦点树，
/// 左右键由外层自己调节数值，上下键回到外层（由设置面板统一做焦点移动）。
class _NavSlider extends StatefulWidget {
  const _NavSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.label,
    required this.onChanged,
  });

  final double value;
  final double min;
  final double max;
  final int divisions;
  final String label;
  final ValueChanged<double>? onChanged;

  @override
  State<_NavSlider> createState() => _NavSliderState();
}

class _NavSliderState extends State<_NavSlider> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'settingsSlider');

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  /// 一格（divisions 均分）的步长
  double get _step => widget.divisions > 0
      ? (widget.max - widget.min) / widget.divisions
      : 0.01;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (widget.onChanged == null) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowLeft &&
        key != LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.ignored;
    }
    final next = (widget.value +
            (key == LogicalKeyboardKey.arrowRight ? _step : -_step))
        .clamp(widget.min, widget.max)
        .toDouble();
    widget.onChanged!(next);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onChanged != null;
    final focused = _focusNode.hasFocus;
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _onKey,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: focused
            ? BoxDecoration(
                border: Border.all(
                    color: enabled ? Colors.blueAccent : Colors.white38),
                borderRadius: BorderRadius.circular(8),
              )
            : null,
        child: ExcludeFocus(
          child: SliderTheme(
            data: SliderThemeData(
              activeTrackColor: Colors.blueAccent,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.blueAccent,
              overlayColor: Colors.blueAccent.withOpacity(0.2),
              disabledActiveTrackColor: Colors.white24,
              disabledThumbColor: Colors.white38,
            ),
            child: Slider(
              value: widget.value,
              min: widget.min,
              max: widget.max,
              divisions: widget.divisions,
              label: widget.label,
              onChanged: widget.onChanged,
            ),
          ),
        ),
      ),
    );
  }
}

// ==================== 系统设置标签页 ====================

class _SystemSettingsTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerController>(
      builder: (context, controller, _) {
        final s = controller.settings;
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            if (controller.isDesktop) ...[
              SwitchListTile(
                secondary: const Icon(Icons.push_pin,
                    color: Colors.white70),
                title: const Text('窗口置顶',
                    style: TextStyle(color: Colors.white, fontSize: 15)),
                subtitle: const Text('窗口始终保持在最前，确保快捷键响应',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
                value: s.alwaysOnTop,
                onChanged: (v) => controller
                    .updateSettings(s.copyWith(alwaysOnTop: v)),
                activeColor: Colors.blueAccent,
              ),
              if (defaultTargetPlatform == TargetPlatform.windows)
                SwitchListTile(
                  secondary:
                      const Icon(Icons.dock, color: Colors.white70),
                  title: const Text('✕ 最小化到托盘',
                      style: TextStyle(color: Colors.white, fontSize: 15)),
                  subtitle: const Text(
                      '点关闭按钮时窗口缩到托盘继续播放，托盘图标左键恢复；'
                      '关着时 ✕ 直接退出。随时可用底部面板「后台播放」',
                      style: TextStyle(color: Colors.white54, fontSize: 12)),
                  value: s.closeToTray,
                  onChanged: (v) => controller
                      .updateSettings(s.copyWith(closeToTray: v)),
                  activeColor: Colors.blueAccent,
                ),
              SwitchListTile(
                secondary: const Icon(Icons.power_settings_new,
                    color: Colors.white70),
                title: const Text('开机启动',
                    style: TextStyle(color: Colors.white, fontSize: 15)),
                subtitle: const Text('开机后自动启动 Omi',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
                value: s.launchAtStartup,
                onChanged: (v) => controller
                    .updateSettings(s.copyWith(launchAtStartup: v)),
                activeColor: Colors.blueAccent,
              ),
              SwitchListTile(
                secondary: const Icon(Icons.fullscreen, color: Colors.white70),
                title: const Text('启动全屏',
                    style: TextStyle(color: Colors.white, fontSize: 15)),
                subtitle: const Text('仅在程序启动时生效一次；启动后双击全屏/还原不受影响',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
                value: s.startFullscreen,
                onChanged: (v) => controller
                    .updateSettings(s.copyWith(startFullscreen: v)),
                activeColor: Colors.blueAccent,
              ),
            ],
            // 开关状态由独立 clockVisible 驱动：切换只重建时钟，不触发
            // 整棵播放 Stack 重建（旧做法反复切换会灰屏）
            ValueListenableBuilder<bool>(
              valueListenable: controller.clockVisible,
              builder: (context, showClock, _) => SwitchListTile(
                secondary:
                    const Icon(Icons.access_time, color: Colors.white70),
                title: const Text('显示时间',
                    style: TextStyle(color: Colors.white, fontSize: 15)),
                subtitle: const Text('右上角一直显示实时系统时间',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
                value: showClock,
                onChanged: controller.setShowClock,
                activeColor: Colors.blueAccent,
              ),
            ),
            // 网页直播支持：关闭后启动不加载 WebView2 运行时环境，
            // 网页频道（webview:// 源）不可用
            ListTile(
              leading: Icon(Icons.language,
                  color: s.webEnabled
                      ? Colors.greenAccent
                      : Colors.white54),
              title: const Text('网页直播支持',
                  style: TextStyle(color: Colors.white, fontSize: 15)),
              subtitle: Text(
                s.webEnabled
                    ? '已开启：支持 webview:// 网页直播源\n关闭后重启不再加载 WebView2（不支持的系统可避免出错）'
                    : '已关闭：启动不加载 WebView2 运行时，网页直播源不可用；重新开启后恢复',
                style: const TextStyle(
                    color: Colors.white54, fontSize: 12),
              ),
              trailing: Switch(
                value: s.webEnabled,
                onChanged: (v) => controller
                    .updateSettings(s.copyWith(webEnabled: v)),
                activeColor: Colors.blueAccent,
              ),
            ),
            // 失败自动重载：网页卡死重载 + 直播流播放失败自动重试，共用次数
            ListTile(
              leading: Icon(Icons.refresh,
                  color: s.autoReloadStall
                      ? Colors.greenAccent
                      : Colors.white54),
              title: const Text('失败自动重载',
                  style: TextStyle(color: Colors.white, fontSize: 15)),
              subtitle: const Text(
                '已开启：网页频道卡死（24 秒不推进）自动重载；'
                '直播流播放失败自动重试当前频道\n'
                '次数用尽仍失败会提示「链接失效」，手动切台或点重试后重新计数',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              trailing: Switch(
                value: s.autoReloadStall,
                onChanged: (v) => controller
                    .updateSettings(s.copyWith(autoReloadStall: v)),
                activeColor: Colors.blueAccent,
              ),
            ),
            // 自动重载/重试次数：3/5/10 次
            ListTile(
              leading: Icon(Icons.repeat,
                  color: s.autoReloadStall
                      ? Colors.white70
                      : Colors.white24),
              enabled: s.autoReloadStall,
              title: Text('自动重试次数',
                  style: TextStyle(
                      color:
                          s.autoReloadStall ? Colors.white : Colors.white38,
                      fontSize: 15)),
              subtitle: Text('每个频道连续失败达到次数后判定链接失效',
                  style: TextStyle(
                      color: s.autoReloadStall
                          ? Colors.white54
                          : Colors.white24,
                      fontSize: 12)),
              trailing: SegmentedButton<int>(
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
                segments: const [3, 5, 10]
                    .map((v) =>
                        ButtonSegment(value: v, label: Text('$v 次')))
                    .toList(),
                selected: {s.retryTimes},
                onSelectionChanged: s.autoReloadStall
                    ? (sel) => controller.updateSettings(
                        s.copyWith(retryTimes: sel.first))
                    : null,
              ),
            ),
            // DLNA 投屏接收状态 + 开关
            ListTile(
              leading: Icon(Icons.cast,
                  color: controller.dlnaRunning
                      ? Colors.greenAccent
                      : Colors.redAccent),
              title: const Text('DLNA 投屏接收',
                  style: TextStyle(color: Colors.white, fontSize: 15)),
              subtitle: Text(
                controller.dlnaRunning
                    ? '已开启：${controller.dlnaName}\n${controller.dlnaEndpoint}\n手机需与本机同一局域网，防火墙需放行本程序'
                    : '未开启：服务已停止或端口被占用',
                style: const TextStyle(
                    color: Colors.white54, fontSize: 12),
              ),
              trailing: Switch(
                value: s.dlnaEnabled,
                onChanged: (v) => controller
                    .updateSettings(s.copyWith(dlnaEnabled: v)),
                activeColor: Colors.blueAccent,
              ),
            ),
            // 投屏点播播完后的处理：立即返回直播 / 等待连播 / 一直等待
            ListTile(
              leading: Icon(Icons.playlist_play,
                  color: s.dlnaEnabled ? Colors.white70 : Colors.white24),
              enabled: s.dlnaEnabled,
              title: Text('投屏结束后',
                  style: TextStyle(
                      color: s.dlnaEnabled ? Colors.white : Colors.white38,
                      fontSize: 15)),
              subtitle: Text('播完/发送端停止后先进「正在等待投屏」：'
                  '等待期间连播（下一集）可直接接上；'
                  '「一直等」则停在等待画面，直到新投屏或双击返回',
                  style: TextStyle(
                      color:
                          s.dlnaEnabled ? Colors.white54 : Colors.white24,
                      fontSize: 12)),
              trailing: SegmentedButton<int>(
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
                segments: const [
                  ButtonSegment(value: 0, label: Text('立即')),
                  ButtonSegment(value: 60, label: Text('1分')),
                  ButtonSegment(value: 300, label: Text('5分')),
                  ButtonSegment(value: 600, label: Text('10分')),
                  ButtonSegment(value: -1, label: Text('一直')),
                ],
                selected: {s.castEndWaitSeconds},
                onSelectionChanged: s.dlnaEnabled
                    ? (sel) => controller.updateSettings(
                        s.copyWith(castEndWaitSeconds: sel.first))
                    : null,
              ),
            ),
            // 局域网 Web 管理：手机扫码增删改直播源/EPG
            ListTile(
              leading: Icon(Icons.qr_code_2,
                  color: s.remoteAdminEnabled &&
                          controller.remoteAdminUrl.isNotEmpty
                      ? Colors.greenAccent
                      : Colors.white54),
              title: const Text('手机扫码管理',
                  style: TextStyle(color: Colors.white, fontSize: 15)),
              subtitle: Text(
                s.remoteAdminEnabled && controller.remoteAdminUrl.isNotEmpty
                    ? '已开启：手机连同一 Wi‑Fi，扫码即可编辑直播源和 EPG\n${controller.remoteAdminUrl}\n'
                        '手机打不开时，请在电脑防火墙提示中允许本程序联网'
                    : (s.remoteAdminEnabled
                        ? '服务启动中或当前平台不支持（端口 8963 起）'
                        : '关闭后局域网内无法通过手机管理'),
                style: const TextStyle(
                    color: Colors.white54, fontSize: 12),
              ),
              trailing: Switch(
                value: s.remoteAdminEnabled,
                onChanged: (v) => controller
                    .updateSettings(s.copyWith(remoteAdminEnabled: v)),
                activeColor: Colors.blueAccent,
              ),
              onTap: controller.remoteAdminUrl.isEmpty
                  ? null
                  : () => showRemoteAdminQrDialog(
                      context, controller.remoteAdminUrl),
            ),
            // 网页频道诊断：复现「打不开/黑屏/串台」后导出日志发给开发者
            ListTile(
              leading: const Icon(Icons.bug_report_outlined,
                  color: Colors.white70),
              title: const Text('导出网页诊断日志',
                  style: TextStyle(color: Colors.white, fontSize: 15)),
              subtitle: const Text(
                  '网页频道故障时使用：先打开故障频道复现一遍，再点这里导出',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              onTap: () async {
                final p = await WebDiag.flush();
                OsdBus.show(
                  p.isEmpty
                      ? '暂无诊断日志：请先打开一次网页频道复现故障'
                      : '诊断日志已导出：$p',
                  icon: Icons.bug_report_outlined,
                );
              },
            ),
            const SizedBox(height: 16),
          ],
        );
      },
    );
  }
}

// ==================== 说明标签页 ====================

/// 说明（参考 OMTV）：键盘/鼠标快捷键、遥控器操作、注意事项
class _HelpTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerController>(
      builder: (context, controller, _) {
        final desktop = controller.isDesktop;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _helpSection('键盘快捷键'),
            _helpInfoCard([
              _helpRow('空格', '播放 / 暂停'),
              _helpRow('F / F11', '全屏切换'),
              _helpRow('M', '静音 / 恢复'),
              _helpRow('C', '频道列表'),
              _helpRow('E', '节目单'),
              _helpRow('S', '设置'),
              _helpRow('R', '录制（仅桌面端）'),
              _helpRow('PrtScr', '截图（仅桌面端）'),
              _helpRow('Alt+W / Ctrl+W', '手机扫码管理二维码'),
              _helpRow('↑ / ↓', '切换频道'),
              _helpRow('← / →', '切换播放源（点播时 ±60 秒快进/快退）'),
              _helpRow('数字键', '直接输入频道号'),
              _helpRow('⏯ / ⏮ / ⏭', '播放暂停 / 上一台 / 下一台'),
              _helpRow('返回 / Esc', '逐层关闭面板，最后弹出退出卡片；锁定时解锁'),
            ]),
            if (desktop) ...[
              _helpSection('鼠标操作'),
              _helpInfoCard([
                _helpRow('双击画面', '全屏 / 还原（小窗模式下为恢复窗口）'),
                _helpRow('鼠标移到屏幕左边缘', '打开频道列表'),
                _helpRow('鼠标移到屏幕右边缘', '打开节目单'),
                _helpRow('鼠标移到屏幕底部', '显示控制面板'),
                _helpRow('鼠标移到屏幕顶部', '呼出标题栏：置顶 / 锁定 / 最小化 / 最大化 / 关闭'),
                _helpRow('底部面板按钮', '静音、全屏、旋转、小窗、重载等可直接点'),
                _helpRow('右键', '相当于返回键，弹出退出卡片'),
                _helpRow('网页频道前台时', '右键被网页接管，可移到底部呼出控制面板后右键，或按 S 键'),
                _helpRow('退出卡片', '返回 / 锁定 / 设置 / 退出 / 关机'),
              ]),
              _helpSection('后台播放与摸鱼模式（Windows）'),
              _helpInfoCard([
                _helpRow('小窗播放', '悬浮置顶的小画面，边干别的边看'),
                _helpRow('后台播放', '底部面板「后台」：窗口缩到托盘只听声，'
                    '托盘图标左键恢复'),
                _helpRow('摸鱼模式', '托盘右键菜单：静音 + 隐藏窗口；'
                    '左键托盘图标一键恢复画面与音量'),
                _helpRow('✕ 最小化到托盘', '设置 → 系统里打开后，'
                    '点关闭按钮不退出、缩到托盘继续播'),
              ]),
            ],
            _helpSection('遥控器'),
            _helpInfoCard([
              _helpRow('方向键 ↑ / ↓', '面板未开时切换频道；面板打开时在面板内移动'),
              _helpRow('方向键 ← / →', '面板未开时切换播放源；面板打开时移动高亮'),
              _helpRow('OK', '短按打开频道列表 / 长按呼出控制面板（面板打开时为确认）'),
              _helpRow('返回', '逐层关闭面板；锁定时解锁'),
              _helpRow('菜单键', '短按节目单 / 长按扫码管理'),
              _helpRow('数字键', '直接输入频道号跳转'),
            ]),
            _helpSection('注意事项'),
            _helpNotesCard([
              '直播源和 EPG 都在本设置里自行添加：可在「播放列表」添加多个 m3u / tvbox / 本地源，'
                  '在「EPG」添加多个 XMLTV 源，随时切换，不是固定源。',
              '网页频道（webview:// 源）依赖 WebView2 运行时。系统不支持时，'
                  '可在「系统」关闭「网页直播支持」，程序启动就不会加载 WebView2；'
                  '即使忘记关闭，检测不到运行时也只会提示不可用，不会崩溃或影响退出。',
              '直播流播放失败会自动重试当前频道，网页频道卡死（24 秒不推进）会自动重载；'
                  '重试次数在「系统」里可调（3/5/10 次），次数用尽会提示链接失效，'
                  '也可随时在底部面板点「重载频道」。',
              '锁定后按键与点击均被屏蔽，按返回键（或方向键 / OK / 菜单键）即可解锁。',
              '手机扫码管理需要手机与电脑连接同一 Wi-Fi，并在防火墙中允许本程序。',
              '台标优先使用源内 tvg-logo，没有则按台名匹配内置台标，仍没有时留空。',
            ]),
          ],
        );
      },
    );
  }
}

Widget _helpSection(String title) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
    child: Text(
      title,
      style: const TextStyle(
        color: Colors.blueAccent,
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 1,
      ),
    ),
  );
}

Widget _helpInfoCard(List<Widget> children) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.white.withOpacity(0.04),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.white12),
    ),
    child: Column(children: children),
  );
}

Widget _helpRow(String key, String desc) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 150,
          child: Text(
            key,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: Text(desc,
              style: const TextStyle(color: Colors.white60, fontSize: 13)),
        ),
      ],
    ),
  );
}

/// 注意事项：逐条小圆点列表
Widget _helpNotesCard(List<String> notes) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: Colors.white.withOpacity(0.04),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.white12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < notes.length; i++)
          Padding(
            padding:
                EdgeInsets.only(bottom: i == notes.length - 1 ? 0 : 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 5, right: 8),
                  child: Icon(Icons.circle,
                      size: 5, color: Colors.blueAccent),
                ),
                Expanded(
                  child: Text(notes[i],
                      style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          height: 1.45)),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

// ==================== 源条目行（播放列表 / EPG 共用） ====================

/// 行尾操作按钮
class _RowAction {
  const _RowAction(this.icon, this.color, this.tooltip, this.onPressed);

  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onPressed;
}

/// 源条目行。遥控器交互：
/// - 上下键：设置面板统一做行间移动（本行只占一个焦点节点，
///   行尾按钮不参与焦点遍历，所以不会停在按钮上出不来）
/// - 左右键：在「整行（选定）」与行尾各按钮之间切换
/// - OK：整行＝选定该源；按钮上＝执行该按钮
class _SourceRow extends StatefulWidget {
  const _SourceRow({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.isCurrent,
    required this.onSelect,
    required this.actions,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final bool isCurrent;

  /// null＝已是当前源，选定无效果
  final VoidCallback? onSelect;
  final List<_RowAction> actions;

  @override
  State<_SourceRow> createState() => _SourceRowState();
}

class _SourceRowState extends State<_SourceRow> {
  final FocusNode _rowNode = FocusNode(debugLabel: 'settingsSourceRow');
  late final List<FocusNode> _actionNodes = List<FocusNode>.generate(
    widget.actions.length,
    (i) => FocusNode(debugLabel: 'settingsSourceRowAction$i'),
  );

  /// 0＝整行（选定），1..n＝第 n 个行尾按钮
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _rowNode.addListener(_onFocusChanged);
    for (final n in _actionNodes) {
      n.addListener(_onFocusChanged);
    }
  }

  @override
  void dispose() {
    _rowNode.removeListener(_onFocusChanged);
    for (final n in _actionNodes) {
      n.removeListener(_onFocusChanged);
      n.dispose();
    }
    _rowNode.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!mounted) return;
    final i = _actionNodes.indexWhere((n) => n.hasFocus);
    setState(() => _index = i < 0 ? 0 : i + 1);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.arrowRight) {
      final target = (k == LogicalKeyboardKey.arrowLeft ? _index - 1 : _index + 1)
          .clamp(0, widget.actions.length)
          .toInt();
      setState(() => _index = target);
      if (target == 0) {
        _rowNode.requestFocus();
      } else {
        _actionNodes[target - 1].requestFocus();
      }
      return KeyEventResult.handled;
    }
    // 整行上按 OK/回车 = 选定该源（按钮上的 OK 由按钮自身处理）
    if (_index == 0 &&
        (k == LogicalKeyboardKey.select ||
            k == LogicalKeyboardKey.enter ||
            k == LogicalKeyboardKey.numpadEnter ||
            k == LogicalKeyboardKey.gameButtonA)) {
      widget.onSelect?.call();
      return KeyEventResult.handled;
    }
    // 上下键交给设置面板统一处理
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final focused = _rowNode.hasFocus || _index > 0;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
      decoration: BoxDecoration(
        color: _rowNode.hasFocus ? Colors.white.withOpacity(0.04) : null,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: focused ? Colors.blueAccent : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: Focus(
        focusNode: _rowNode,
        onKeyEvent: _onKey,
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onSelect,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Row(
                    children: [
                      Icon(
                        widget.icon,
                        size: 22,
                        color: widget.isCurrent
                            ? Colors.blueAccent
                            : Colors.white54,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: widget.isCurrent
                                    ? Colors.blueAccent
                                    : Colors.white,
                                fontWeight: widget.isCurrent
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                            Text(
                              widget.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white38, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // 当前正在使用：蓝色对号（仅状态标识）
            if (widget.isCurrent)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.check_circle,
                    color: Colors.blueAccent, size: 20),
              ),
            // 行尾按钮：不参与上下遍历，只能用左右键在行内进入
            Focus(
              skipTraversal: true,
              descendantsAreTraversable: false,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < widget.actions.length; i++)
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: _actionNodes[i].hasFocus
                              ? Colors.white70
                              : Colors.transparent,
                        ),
                      ),
                      child: IconButton(
                        focusNode: _actionNodes[i],
                        visualDensity: VisualDensity.compact,
                        iconSize: 20,
                        tooltip: widget.actions[i].tooltip,
                        icon: Icon(widget.actions[i].icon,
                            color: widget.actions[i].color),
                        onPressed: widget.actions[i].onPressed,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

// ==================== 公共工具 ====================

/// 弹出局域网管理地址二维码（设置面板与底部控制面板遥控器入口共用）。
///
/// 白色圆角卡片 + 圆角模块二维码，URL 独立底色展示，
/// 「复制地址 / 关闭」两个按钮等高并排，遥控器返回键也可关闭。
Future<void> showRemoteAdminQrDialog(BuildContext context, String url) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withOpacity(0.72),
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 360),
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
        decoration: BoxDecoration(
          color: const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('手机扫码管理',
                style: TextStyle(
                    color: Color(0xFF11141B),
                    fontSize: 18,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            const Text('手机与电脑连接同一 Wi‑Fi',
                style: TextStyle(color: Colors.black45, fontSize: 13)),
            const SizedBox(height: 18),
            // 二维码：白底圆角卡片内嵌圆角方块码，四周留白保证可识别
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.07),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: QrImageView(
                data: url,
                version: QrVersions.auto,
                size: 216,
                backgroundColor: Colors.white,
                padding: EdgeInsets.zero,
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: Color(0xFF141821),
                ),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Color(0xFF141821),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFECEEF2),
                borderRadius: BorderRadius.circular(9),
              ),
              child: SelectableText(
                url,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Color(0xFF333A47),
                    fontSize: 14,
                    fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: url));
                      if (!ctx.mounted) return;
                      Navigator.pop(ctx);
                      OsdBus.show('地址已复制', icon: Icons.copy);
                    },
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('复制地址'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF333A47),
                      side: const BorderSide(color: Color(0xFFD2D7E0)),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(11)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2563EB),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(11)),
                    ),
                    child: const Text('关闭'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// 是否显示地址输入框后缀的「剪贴板」按钮。
/// 仅安卓端需要：系统长按菜单在没有输入法（电视盒子/部分 ROM）时
/// 弹不出来，给一个常驻按钮。桌面端右键菜单够用，不加按钮。
bool get _showPasteButton =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// 应用内剪贴板历史：Flutter 读不到系统剪贴板历史，只能在前台
/// 周期性采样，记录最近复制过的文本，供粘贴按钮弹出选择
class _ClipHistory {
  static final List<String> items = <String>[];
  static Timer? _timer;
  static String? _last;

  static void ensureWatching() {
    if (_timer != null) return;
    _timer = Timer.periodic(
        const Duration(milliseconds: 1500), (_) => _sample());
    _sample();
  }

  static Future<void> _sample() async {
    try {
      final d = await Clipboard.getData(Clipboard.kTextPlain);
      final t = d?.text?.trim();
      if (t == null || t.isEmpty || t == _last) return;
      _last = t;
      items.remove(t);
      items.insert(0, t);
      if (items.length > 20) items.removeRange(20, items.length);
    } catch (_) {}
  }

  static Future<void> sampleNow() => _sample();
}

/// 地址输入框后缀的「剪贴板」按钮：弹出最近复制过的文本，点选后填入
class _PasteIconButton extends StatelessWidget {
  final TextEditingController controller;

  const _PasteIconButton(this.controller);

  Future<void> _open(BuildContext context) async {
    await _ClipHistory.sampleNow();
    final list = List<String>.from(_ClipHistory.items);
    if (list.isEmpty) {
      OsdBus.show('剪贴板是空的', icon: Icons.content_paste_off);
      return;
    }
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从剪贴板选择'),
        content: SizedBox(
          width: 460,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: list.length,
              separatorBuilder: (_, __) =>
                  const Divider(color: Colors.white12, height: 1),
              itemBuilder: (_, i) => ListTile(
                dense: true,
                title: Text(
                  list[i],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () => Navigator.pop(ctx, list[i]),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (picked == null) return;
    controller.text = picked;
    controller.selection = TextSelection.collapsed(offset: picked.length);
    OsdBus.show('已粘贴', icon: Icons.content_paste);
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.content_paste, size: 20),
      tooltip: '剪贴板',
      color: Colors.white70,
      visualDensity: VisualDensity.compact,
      onPressed: () => _open(context),
    );
  }
}

InputDecoration _inputDecoration(String hint,
    [TextEditingController? pasteTarget]) {
  return InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: Colors.white38),
    filled: true,
    fillColor: Colors.white10,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide.none,
    ),
    contentPadding:
        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    // 剪贴板按钮仅安卓端显示（桌面端用右键菜单）
    suffixIcon: (pasteTarget == null || !_showPasteButton)
        ? null
        : _PasteIconButton(pasteTarget),
  );
}

/// 换台跳过入口：自己管加载与刷新（关键词增删后要更新副标题）
class _BlacklistRow extends StatefulWidget {
  const _BlacklistRow();

  @override
  State<_BlacklistRow> createState() => _BlacklistRowState();
}

class _BlacklistRowState extends State<_BlacklistRow> {
  @override
  void initState() {
    super.initState();
    ChannelBlacklist.ensure().then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _open() async {
    await ChannelBlacklist.ensure();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierColor: AppColors.scrim,
      builder: (_) => const _BlacklistDialog(),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final keys = ChannelBlacklist.keywords;
    return ListTile(
      leading: const Icon(Icons.block, color: Colors.white70),
      title: const Text('换台跳过',
          style: TextStyle(color: Colors.white, fontSize: 15)),
      subtitle: Text(
        keys.isEmpty
            ? '未设置：上下换台会依次停在每个频道'
            : '已跳过 ${keys.length} 个关键词：${keys.join('、')}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white54, fontSize: 12),
      ),
      trailing: const Icon(Icons.chevron_right,
          color: Colors.white38, size: 20),
      onTap: _open,
    );
  }
}

/// 换台跳过的关键词管理（方案 12.3 第一档）
class _BlacklistDialog extends StatefulWidget {
  const _BlacklistDialog();

  @override
  State<_BlacklistDialog> createState() => _BlacklistDialogState();
}

class _BlacklistDialogState extends State<_BlacklistDialog> {
  final TextEditingController _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final k = _ctl.text.trim();
    if (k.isEmpty) return;
    await ChannelBlacklist.add(k);
    _ctl.clear();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final keys = ChannelBlacklist.keywords;
    return AlertDialog(
      backgroundColor: AppColors.overlay,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.stroke),
      ),
      title: const Text('换台跳过',
          style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '命中关键词的频道/电台，上下换台时自动跳过。'
              '列表里仍然可见，手动点播不受影响。',
              style: TextStyle(
                  color: AppColors.textTertiary, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 12),
            if (keys.isEmpty)
              const Text('还没有屏蔽词',
                  style: TextStyle(
                      color: AppColors.textTertiary, fontSize: 12.5))
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final k in keys)
                    Chip(
                      label: Text(k,
                          style: const TextStyle(
                              color: AppColors.textPrimary, fontSize: 12)),
                      backgroundColor: Colors.white.withValues(alpha: 0.06),
                      side: const BorderSide(color: AppColors.stroke),
                      deleteIconColor: AppColors.textTertiary,
                      onDeleted: () async {
                        await ChannelBlacklist.remove(k);
                        if (mounted) setState(() {});
                      },
                    ),
                ],
              ),
            const SizedBox(height: 14),
            _ImeSafeTextField(
              controller: _ctl,
              style: const TextStyle(
                  color: AppColors.textPrimary, fontSize: 13.5),
              onSubmitted: (_) => _add(),
              decoration: InputDecoration(
                hintText: '关键词，如「购物」「测试」「戏曲」',
                hintStyle: const TextStyle(
                    color: AppColors.textTertiary, fontSize: 12.5),
                isDense: true,
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: AppColors.stroke),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: AppColors.stroke),
                ),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.add_circle_outline,
                      size: 18, color: AppColors.textSecondary),
                  onPressed: _add,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
