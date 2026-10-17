/// Aurum · 玻璃面板（对应原版 .glass / .sidebar 材质）。
/// 半透渐变 + 1px 渐变描边（顶部高光）+ 大投影；不叠 BackdropFilter，
/// 避免与逐帧重绘的词云/频谱画布互相触发合成层重算（原版实测崩溃教训）。
library;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding,
    this.radius = kGlassRadius,
    this.heavy = false,
    /// 是否裁剪超出圆角的内容。默认裁剪；
    /// 但播放器面板要传 false —— 频谱环画布是封面的 1.6 倍，
    /// 高潮辉光会溢出面板边界，原版 CSS 面板并不裁剪（无 overflow:hidden），
    /// 若在此裁剪会把环的顶部/底部削平。
    this.clip = true,
  });

  final Widget child;
  final EdgeInsets? padding;
  final double radius;
  /// 侧栏等结构层：更重的材质（深色渐变）
  final bool heavy;
  /// 见构造函数注释：播放器面板需关闭裁剪，让频谱环/辉光可以溢出面板边界。
  final bool clip;

  @override
  Widget build(BuildContext context) {
    var content = child;
    if (padding != null) {
      content = Padding(padding: padding!, child: content);
    }
    final stack = Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(painter: _GlassPainter(radius, heavy)),
        ),
        content,
      ],
    );
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.38),
            blurRadius: 64,
            offset: const Offset(0, 24),
          ),
        ],
      ),
      child: clip
          ? ClipRRect(borderRadius: BorderRadius.circular(radius), child: stack)
          : stack,
    );
  }
}

class _GlassPainter extends CustomPainter {
  const _GlassPainter(this.radius, this.heavy);
  final double radius;
  final bool heavy;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect =
        RRect.fromRectAndRadius(rect, Radius.circular(radius));

    // 渐变底（135°：左上 → 右下）
    final bgPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: heavy ? kSidebarGradientColors : kGlassGradientColors,
      ).createShader(rect);
    canvas.drawRRect(rrect, bgPaint);

    // 1px 描边：顶部高光 → 底部稍亮（对应 inset 0 1px 0 高光 + 玻璃边）
    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          kGlassHighlight,
          kGlassBorder.withValues(alpha: 0.12),
          kGlassBorder.withValues(alpha: 0.35),
        ],
        stops: const [0, 0.55, 1],
      ).createShader(rect);
    canvas.drawRRect(rrect, borderPaint);
  }

  @override
  bool shouldRepaint(_GlassPainter old) =>
      old.radius != radius || old.heavy != heavy;
}
