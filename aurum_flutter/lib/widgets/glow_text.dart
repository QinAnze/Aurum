/// Aurum · 文字光晕（对应原版 npInfoEl.style.filter = drop-shadow(...)）。
/// 两层白光跟随字形 alpha 真正贴字发光，而非字下背景块；
/// 亮度/光晕与 climax 成正比，归零即自然消失。
library;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class GlowText extends StatelessWidget {
  const GlowText(
    this.text, {
    super.key,
    this.style,
    this.glow = 0,
    this.blur = 0,
    this.maxLines = 1,
    this.textAlign = TextAlign.center,
  });

  final String text;
  final TextStyle? style;
  /// 光晕强度 0..1
  final double glow;
  /// 光晕半径 px
  final double blur;
  final int maxLines;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) {
    final base = style ?? fontStyle();
    // 量化 glow / blur：climax 每帧都在动，若把连续值直接塞进 TextStyle，
    // 每帧都是「新样式」→ Text 每帧重新排版（CJK 标题重排很贵）。
    // 量化后绝大多帧样式完全相同，TextStyle 值相等 → RenderParagraph 跳过重排，
    // 只剩外层 Transform 换矩阵，这才是 CSS filter 的开销量级。
    final g = (glow * 24).round() / 24;
    final b = (blur * 2).round() / 2;
    return Text(
      text,
      style: g <= 0.001
          ? base
          : base.copyWith(shadows: [
              Shadow(
                color: const Color.fromRGBO(255, 255, 255, 1)
                    .withValues(alpha: 0.95 * g),
                blurRadius: b * 0.45,
              ),
              Shadow(
                color: const Color.fromRGBO(255, 248, 228, 1)
                    .withValues(alpha: 0.6 * g),
                blurRadius: b,
              ),
            ]),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      textAlign: textAlign,
    );
  }
}
