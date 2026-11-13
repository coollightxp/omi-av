import 'package:flutter/material.dart';

import '../../models/channel.dart';
import '../../services/channel_logo.dart';
import '../../services/radio_logo.dart';

/// 统一台标（电视 / 电台共用）。
///
/// 四级回退，逐级降级、永不空白：
/// 1. 内置 `assets/logos`（按台名匹配，离线可用、质量最好）
/// 2. 源里给的在线 `tvg-logo`
/// 3. Radio Browser 按台名补的 favicon（走 [RadioLogo] 的本地索引）
/// 4. 字母台标：深蓝渐变底 + 白色首字
///
/// 电台用圆形（广播台的行业惯例），电视用圆角方形，两者靠 [circular]
/// 区分，也可以由调用方显式指定。
class ChannelBadge extends StatelessWidget {
  const ChannelBadge({
    super.key,
    required this.channel,
    this.size = 24,
    this.width,
    this.circular,
    this.background = const Color(0x14FFFFFF),
    this.extraLogoUrls = const [],
  });

  final Channel channel;
  final double size;

  /// 容器宽度。不传 = 正方形 [size]×[size]。
  ///
  /// 不少台标是横向长图（圆标 + 台名文字，如各省卫视官方 logo），
  /// 塞进正方形里 contain 会缩成很小一团；底部信息面板这类横向空间
  /// 充裕的地方给 1.6 倍宽度，横向 logo 就能铺开显示
  final double? width;

  /// 为空时按频道类型决定：电台圆形、电视圆角方
  final bool? circular;

  /// 图片底衬色（透明台标叠在深色背景上更容易看清）
  final Color background;

  /// 额外的在线候选（如 EPG 匹配到的台标），按顺序排在
  /// `channel.logoUrl` 之后尝试；用于保留旧面板「EPG icon 优先」的行为
  final List<String> extraLogoUrls;

  bool get _isRound => circular ?? channel.isRadio;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius:
          BorderRadius.circular(_isRound ? size / 2 : size * 0.22),
      child: Container(
        width: width ?? size,
        height: size,
        color: background,
        child: _content(),
      ),
    );
  }

  Widget _content() {
    final asset = ChannelLogo.assetFor(channel);
    if (asset.isNotEmpty) {
      return Image.asset(
        asset,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => _remote(0),
      );
    }
    return _remote(0);
  }

  /// 在线候选逐个尝试：channel.logoUrl → extraLogoUrls → Radio Browser
  List<String> get _urls => [
        if (channel.logoUrl.isNotEmpty) channel.logoUrl,
        ...extraLogoUrls.where((u) => u.isNotEmpty),
      ];

  Widget _remote(int i) {
    final urls = _urls;
    if (i >= urls.length) return _radioThenLetter();
    return Image.network(
      urls[i],
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => _remote(i + 1),
    );
  }

  Widget _radioThenLetter() {
    final fb = RadioLogo.logoFor(channel);
    if (fb.isNotEmpty) {
      return Image.network(
        fb,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => _letter(),
      );
    }
    return _letter();
  }

  /// 字母台标：深蓝底 + 白色首字。
  /// 电台取前两个字（「中国之声」→「中国」在 24px 下挤，仍只取首字），
  /// 英文取前两位（CNR / CRI 这类缩写比单字母好认）。
  Widget _letter() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1E3A8A), Color(0xFF0F172A)],
        ),
      ),
      alignment: Alignment.center,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: EdgeInsets.all(size * 0.14),
          child: Text(
            _initials(channel.name),
            maxLines: 1,
            style: TextStyle(
              color: Colors.white,
              fontSize: size * 0.46,
              fontWeight: FontWeight.w700,
              height: 1,
              letterSpacing: 0,
            ),
          ),
        ),
      ),
    );
  }

  static String _initials(String name) {
    final s = name.trim();
    if (s.isEmpty) return '📻';
    // 中文/日韩：首字
    final first = s.characters.first;
    if (RegExp(r'[\u4e00-\u9fa5\u3040-\u30ff]').hasMatch(first)) {
      return first;
    }
    // 英文数字：取前两位字母（跳过空格与符号）
    final letters = s.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    if (letters.isEmpty) return first;
    return letters.substring(0, letters.length >= 2 ? 2 : 1).toUpperCase();
  }
}
