/// Aurum · 动态背景（对应原版 .bg-cover / .bg-tint×2 / 底色）。
///  - 封面大图：blur(45σ) + 饱和 1.7 + 压暗，scale 1.4，opacity .38
///  - 双层 tint：封面取色径向渐变，换色时交叉淡化（真实双色过渡）
///  - 26s 缓慢漂移；深色底（替代原版透明窗口透出桌面的效果）
library;

import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../net_image.dart';
import '../theme/tokens.dart';

class BackgroundLayers extends StatefulWidget {
  const BackgroundLayers({
    super.key,
    required this.coverUrl,
    required this.c1,
    required this.c2,
    required this.flip,
  });

  final String? coverUrl;
  final Color c1;
  final Color c2;
  /// 双层交叉淡化切换位
  final bool flip;

  @override
  State<BackgroundLayers> createState() => _BackgroundLayersState();
}

class _BackgroundLayersState extends State<BackgroundLayers>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 26),
  )..repeat(reverse: true);

  Color _a1 = kDefaultC1, _a2 = kDefaultC2;
  Color _b1 = kDefaultC1, _b2 = kDefaultC2;
  bool _showA = true;

  @override
  void initState() {
    super.initState();
    _a1 = widget.c1;
    _a2 = widget.c2;
  }

  @override
  void didUpdateWidget(BackgroundLayers old) {
    super.didUpdateWidget(old);
    if (old.c1 != widget.c1 || old.c2 != widget.c2) {
      // 新色只应用到即将显示的层，隐藏层保留旧色 → fade 过程形成真实双色过渡
      _showA = !_showA;
      if (_showA) {
        _a1 = widget.c1;
        _a2 = widget.c2;
      } else {
        _b1 = widget.c1;
        _b2 = widget.c2;
      }
    }
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        // 深色底
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: kBaseGradient,
            ),
          ),
        ),
        // 模糊封面大图
        if (widget.coverUrl != null)
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: 0.38,
                child: Transform.scale(
                  scale: 1.4,
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 45, sigmaY: 45),
                    child: ColorFiltered(
                      colorFilter: _saturation(1.7),
                      child: Image(
                        image: aurumImage(widget.coverUrl!),
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        // 双层 tint 交叉淡化 + 26s 漂移
        IgnorePointer(
          child: AnimatedBuilder(
            animation: _drift,
            builder: (_, __) {
              final t = _drift.value;
              final dx = math.sin(t * math.pi * 2) * size.width * 0.03;
              final dy = math.cos(t * math.pi * 2) * size.height * 0.04;
              return Transform.translate(
                offset: Offset(dx, dy),
                child: Transform.scale(
                  scale: 1.12,
                  alignment: Alignment.center,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _tintLayer(_a1, _a2, _showA ? 0.9 : 0),
                      _tintLayer(_b1, _b2, _showA ? 0 : 0.9),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _tintLayer(Color c1, Color c2, double opacity) {
    return AnimatedOpacity(
      opacity: opacity,
      duration: const Duration(milliseconds: kBgFadeMs),
      curve: kEaseInOut,
      child: SizedBox.expand(
        child: CustomPaint(
          painter: _TintPainter(c1, c2),
        ),
      ),
    );
  }
}

/// 饱和度矩阵（ColorFilter.matrix）
ColorFilter _saturation(double s) {
  final r = 0.213 + 0.787 * s;
  final g = 0.715 - 0.715 * s;
  final b = 0.072 - 0.072 * s;
  return ColorFilter.matrix([
    r, g, b, 0, 0,
    0.213 - 0.213 * s, 0.715 + 0.285 * s, 0.072 - 0.072 * s, 0, 0,
    0.213 - 0.213 * s, 0.715 - 0.715 * s, 0.072 + 0.928 * s, 0, 0,
    0, 0, 0, 1, 0,
  ]);
}

class _TintPainter extends CustomPainter {
  const _TintPainter(this.c1, this.c2);
  final Color c1;
  final Color c2;

  @override
  void paint(Canvas canvas, Size size) {
    void radial(double fx, double fy, double radius, Color color,
        double alpha, double stop) {
      final paint = Paint()
        ..shader = RadialGradient(
          center: Alignment(fx * 2 - 1, fy * 2 - 1),
          radius: radius,
          colors: [color.withValues(alpha: alpha), Colors.transparent],
          stops: [0, stop],
        ).createShader(Offset.zero & size);
      canvas.drawRect(Offset.zero & size, paint);
    }

    // 对应原版三层 radial-gradient
    radial(0.15, 0.10, 1.2, c1, 0.34, 0.60);
    radial(0.85, 0.85, 1.0, c2, 0.30, 0.62);
    radial(0.60, 0.30, 0.8, c1, 0.16, 0.70);
  }

  @override
  bool shouldRepaint(_TintPainter old) => old.c1 != c1 || old.c2 != c2;
}
