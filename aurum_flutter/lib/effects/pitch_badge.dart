/// 音高字母：检测到的音以「E5」这种形式落在封面正中央。
///
/// 与词云刻意分层：词云在背景层，这个是**顶层覆盖层**（不参与词云布局，
/// 也不会被词云的封面禁区裁掉）。视觉语言沿用词云那套：
///  - 进场：从下方 ease-out quad 减速升起（与词云 rise 同一条曲线）
///  - 退场：ease-in quad 加速坠落 + 淡出（与词云 fall 同一条曲线）
///  - 字形：SmileySans bold + 主题色双层光晕，入场时更亮、落位后收敛
///
/// 三种节奏：
///  - 从无到有（一整段开始）→ 完整升起 560ms
///  - 段内换音 → 短促再升 320ms（幅度小，像新字轻轻顶上来）
///  - 段落结束 / 唱完 → 向下坠落 380ms
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

class PitchBadge extends StatefulWidget {
  const PitchBadge({
    super.key,
    required this.note,
    required this.revision,
    required this.rect,
    required this.c1,
    this.glow = 0,
    this.blur = 0,
    this.scale = 1,
  });

  /// 音名（'E5'）；null 表示不显示
  final String? note;
  /// 每次音名变化 +1（保留给外部触发用；动画本身按 note 变化重放）
  final int revision;
  /// 封面的全局矩形（决定落点）
  final Rect? rect;
  /// 主题主色（光晕颜色）
  final Color c1;

  /// climax 驱动的光晕强度 0..1（与歌曲标题同一套）
  final double glow;
  /// climax 驱动的光晕半径 px
  final double blur;
  /// climax 驱动的放大系数（>=1）
  final double scale;

  @override
  State<PitchBadge> createState() => _PitchBadgeState();
}

class _PitchBadgeState extends State<PitchBadge>
    with SingleTickerProviderStateMixin {
  /// 从无到有：完整升起
  static const _kEnterMs = 560;
  /// 段内换音：短促再升
  static const _kSwapMs = 320;
  /// 落下去
  static const _kExitMs = 380;

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: _kEnterMs),
  );

  /// 当前（或正在退场）显示的音名
  String? _shown;
  bool _leaving = false;
  /// 本次进场的位移倍数：整段开始 1.0，换音 0.45
  double _rise = 1;

  @override
  void initState() {
    super.initState();
    _c.addStatusListener(_onStatus);
    final n = widget.note;
    if (n != null) {
      _shown = n;
      _c.forward(from: 0);
    }
  }

  @override
  void didUpdateWidget(PitchBadge old) {
    super.didUpdateWidget(old);
    final n = widget.note;
    if (n == _shown) return;

    if (n == null) {
      // 段落结束 / 唱完：向下落
      if (_shown == null) return;
      _leaving = true;
      _c.duration = const Duration(milliseconds: _kExitMs);
      _c.reverse();
      return;
    }

    // 新音：整段开始 → 完整升起；段内换音 → 轻轻再升
    final wasEmpty = _shown == null;
    _leaving = false;
    _shown = n;
    _rise = wasEmpty ? 1.0 : 0.45;
    _c.duration = Duration(milliseconds: wasEmpty ? _kEnterMs : _kSwapMs);
    _c.forward(from: 0);
  }

  void _onStatus(AnimationStatus s) {
    if (s == AnimationStatus.dismissed && _leaving) {
      setState(() {
        _shown = null;
        _leaving = false;
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final note = _shown;
    final rect = widget.rect;
    if (note == null || rect == null || rect.isEmpty) {
      return const SizedBox.shrink();
    }

    // 字号跟封面走。像素字笔画细，比之前的衬线调大一档才压得住
    final size = rect.width * 0.22;
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned.fromRect(
            rect: rect,
            child: Center(
              child: AnimatedBuilder(
                animation: _c,
                builder: (context, _) {
                  final v = _c.value.clamp(0.0, 1.0);
                  // 与词云 rise/fall 同一条曲线：减速上升、加速坠落
                  final rise = 1 - (1 - v) * (1 - v);
                  // 上移半个字高：把封面圆心让给下方的直线频谱，
                  // 上移量 0.52*字号，字顶仍在圆内（0.52+0.5=1.02 字高 ≈ 0.22 封面宽）
                  final dy =
                      (1 - rise) * size * 1.25 * _rise - size * 0.52;
                  final alpha = _leaving
                      ? (1 - math.pow(1 - v, 2.2) as double)
                      : math.min(1.0, v * 2.2);
                  // 入场时更亮，落位后收敛成常亮光晕；
                  // 高潮时整体再亮一档、半径更大（与歌曲标题同一条曲线）
                  // 量化：climax 每帧都在动，连续值会让 Text 每帧重排版
                  final g = (widget.glow * 24).round() / 24;
                  final b = (widget.blur * 2).round() / 2;
                  // 光晕色往白里提 —— 直接用主题色时，深色背景上那圈
                  // 暗金/暗蓝几乎和背景融在一起，看着像「根本没发光」。
                  final halo = Color.lerp(widget.c1, Colors.white, 0.80)!;
                  // 基础光晕刻意压小，把动态范围让给 climax：
                  // 常亮只留一圈贴字微光（≈0.26 字高），高潮时放大到近 4 倍，
                  // 这样「发光特效」才看得出来，而不是一直糊着。
                  final boost = 1 + g * 3.0;
                  final glow =
                      size * (0.26 + 0.52 * math.pow(1 - v, 3)) * boost;
                  final aura = b * 1.8;
                  final style = TextStyle(
                    // 与背景平铺统一成像素体（用户要求）。像素字只有一个字重，
                    // 传 fontWeight 会被引擎合成假粗体、把像素边糊掉。
                    inherit: false,
                    fontFamily: 'AurumPixel',
                    fontSize: size,
                    height: 1.0,
                    letterSpacing: 0,
                    color: Colors.white.withValues(alpha: 0.96 * alpha),
                    shadows: [
                      // 贴字一层（半径 ≈ 半个字高），先把字的边缘烧亮
                      Shadow(
                        color: halo.withValues(alpha: 1.0 * alpha),
                        blurRadius: glow * 0.55,
                      ),
                      Shadow(
                        color: halo.withValues(alpha: 0.85 * alpha),
                        blurRadius: glow,
                      ),
                      Shadow(
                        color: halo.withValues(alpha: 0.55 * alpha),
                        blurRadius: glow * 2.2,
                      ),
                      // 高潮时才有的第四层大光斑（半径由 climax 给）
                      if (aura > 0.5)
                        Shadow(
                          color: halo.withValues(alpha: 0.62 * alpha * g),
                          blurRadius: aura,
                        ),
                    ],
                  );
                  return Opacity(
                    opacity: alpha.clamp(0.0, 1.0),
                    child: Transform.translate(
                      offset: Offset(0, dy),
                      child: Transform.scale(
                        // 入场时从 96% 顶到 100%，高潮再整体放大
                        scale: (0.96 + 0.04 * rise) * widget.scale,
                        child: Text(note, style: style),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
