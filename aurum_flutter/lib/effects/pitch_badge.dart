/// 音高字母：两句歌词之间的长间隙里，检测到的最高音以「E5」这种形式
/// 蹦到封面正中间。
///
/// 与词云刻意分层：词云在背景层，这个是**顶层覆盖层**（不参与词云布局，
/// 也不会被词云的封面禁区裁掉）。样式沿用词云那套字形（SmileySans bold +
/// 同色光晕），弹出用 easeOutBack 的过冲，落位后一直停住。
library;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class PitchBadge extends StatefulWidget {
  const PitchBadge({
    super.key,
    required this.note,
    required this.revision,
    required this.rect,
    required this.c1,
  });

  /// 音名（'E5'）；null 表示不显示
  final String? note;
  /// 每次音名变化 +1，用来重放弹出动画
  final int revision;
  /// 封面的全局矩形（决定落点）
  final Rect? rect;
  /// 主题主色（光晕颜色）
  final Color c1;

  @override
  State<PitchBadge> createState() => _PitchBadgeState();
}

class _PitchBadgeState extends State<PitchBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 460),
  );

  @override
  void initState() {
    super.initState();
    if (widget.note != null) _pop.forward(from: 0);
  }

  @override
  void didUpdateWidget(PitchBadge old) {
    super.didUpdateWidget(old);
    // 换了音符（更响/更高的音被锁定）或首次出现：重放弹出
    if (widget.note != null && widget.note != old.note) {
      _pop.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final note = widget.note;
    final rect = widget.rect;
    if (note == null || rect == null || rect.isEmpty) {
      return const SizedBox.shrink();
    }

    final size = rect.width * 0.2; // 字号跟封面走
    final style = TextStyle(
      fontFamily: 'SmileySans',
      fontWeight: FontWeight.bold,
      fontSize: size,
      height: 1.0,
      letterSpacing: -0.02 * size,
      color: Colors.white.withValues(alpha: 0.96),
      shadows: [
        Shadow(color: widget.c1.withValues(alpha: 0.95), blurRadius: size * 0.3),
        Shadow(
          color: widget.c1.withValues(alpha: 0.55),
          blurRadius: size * 0.95,
        ),
      ],
    );

    return IgnorePointer(
      child: Stack(
        children: [
          Positioned.fromRect(
            rect: rect,
            child: Center(
              child: AnimatedBuilder(
                animation: _pop,
                builder: (_, child) {
                  final t = kEaseOut.transform(_pop.value);
                  // 过冲弹入：0.62 → 1.06 → 1.0
                  final back = Curves.easeOutBack.transform(_pop.value);
                  final scale = 0.62 + 0.38 * back;
                  final opacity = (t * 2.4).clamp(0.0, 1.0);
                  return Opacity(
                    opacity: opacity,
                    child: Transform.translate(
                      offset: Offset(0, 12 * (1 - t)),
                      child: Transform.scale(scale: scale, child: child),
                    ),
                  );
                },
                child: Text(note, style: style),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
