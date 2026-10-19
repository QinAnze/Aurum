/// 音高散落（非歌词段专用）。
///
/// 与 [PitchBadge] 是**两套互不相干的视觉**，按相位二选一：
///  - 人声段（歌词）：封面中央单个字母，从下升起 + 发光 —— 见 pitch_badge.dart
///  - 乐器段（>8s 间隙）：底部随机散落，每换一个音就多一个字母，
///    直接出现（无位移、无淡入、无光晕），放满整屏就清空重来
///
/// 落点规则：只在下半屏的一条横带里撒（[bandTop]~[bottom]），按列切片随机取列，
/// 列内随机取行，与已有字母做矩形避让；同一列排满就换列，全排满即清空。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 一个已经落位的字母
class ScatterWord {
  ScatterWord({
    required this.text,
    required this.x,
    required this.y,
    required this.size,
    required this.color,
  });

  final String text;
  final double x;
  final double y;
  final double size;
  final Color color;
}

class _Rect {
  const _Rect(this.x, this.y, this.w, this.h);
  final double x, y, w, h;

  bool hits(double ox, double oy, double ow, double oh) =>
      ox < x + w && ox + ow > x && oy < y + h && oy + oh > y;
}

/// 纯数据控制器：由 [VizController] 逐帧驱动，widget 只负责画。
class PitchScatterController {
  /// 已落位的字母（按放置顺序排列，画的时候可以整层重建）
  final List<ScatterWord> words = [];

  /// 撒字横带占视口高度的比例（从这条线到底边）
  static const double bandTop = 0.62;

  /// 一个字母占的最大宽度比例（切片列数由字号反推）
  static const int maxColumns = 14;

  final math.Random _rng = math.Random();
  List<_Rect> _placed = [];

  /// 满屏阈值：放这么多就清空重来（不写死像素，按屏幕能塞多少算）
  int _capacity = 60;
  Size _size = Size.zero;

  /// 当前视口（未 layout 过时是 Size.zero）
  Size get viewport => _size;

  bool get isEmpty => words.isEmpty;

  /// 视口尺寸变化（或首帧）时调用：重算容量，避免换窗口后永远塞不满
  void layout(Size size) {
    if (size == _size) return;
    _size = size;
    _capacity = computeCapacity(size);
  }

  /// 清空（进入人声段 / 切歌 / 关特效）
  void clear() {
    if (words.isEmpty) return;
    words.clear();
    _placed = [];
  }

  /// 每检测到一个新音高调用一次：[rnd] 外部注入，保证测试可确定性。
  ///
  /// 返回 false 表示这次没地方放（已自动清空，下次从空屏重来）。
  bool spawn(String note, {math.Random? rnd}) {
    final r = rnd ?? _rng;
    final size = _size;
    if (size.isEmpty || note.isEmpty) return false;
    layout(size);

    final fontSize = (size.width * 0.026).clamp(13.0, 34.0);
    final (tw, th) = measure(note, fontSize);
    if (tw <= 0 || th <= 0) return false;

    final top = size.height * bandTop;
    final bottom = size.height - 6;
    final bandH = bottom - top;
    if (bandH < th) return false;

    // 列切片：列宽略大于字母宽度，保证一行里最多一个字母
    final cols = math.min(maxColumns, math.max(1, (size.width / (tw + 10)).floor()));
    final colW = size.width / cols;
    final order = List<int>.generate(cols, (i) => i)..shuffle(r);

    for (final c in order) {
      final span = math.max(1, (bandH / (th + 6)).floor());
      final rows = List<int>.generate(span, (i) => i)..shuffle(r);
      for (final row in rows) {
        // 在切片内再抖一点，避免排成整齐的网格
        final jx = r.nextDouble() * math.max(0.0, colW - tw - 8) + 4;
        final x = (c * colW + jx)
            .clamp(4.0, math.max(4.0, size.width - tw - 4))
            .toDouble();
        final y = (top + row * (th + 6) + r.nextDouble() * 4)
            .clamp(top, math.max(top, bottom - th))
            .toDouble();
        if (_placed.any((p) => p.hits(x, y, tw, th))) continue;
        _place(note, x, y, tw, th, fontSize);
        return true;
      }
    }

    // 全屏塞满：清空，本次不计（下一帧还会继续来新音）
    clear();
    return false;
  }

  void _place(
    String note,
    double x,
    double y,
    double tw,
    double th,
    double fontSize,
  ) {
    if (words.length >= _capacity) {
      clear();
    }
    words.add(ScatterWord(text: note, x: x, y: y, size: fontSize, color: Colors.white));
    _placed.add(_Rect(x, y, tw, th));
  }

  /// 按屏幕尺寸估一个容量（每个字母约占 (字号×2.2)² 的面积）
  static int computeCapacity(Size size) {
    if (size.isEmpty) return 60;
    final fontSize = (size.width * 0.026).clamp(13.0, 34.0);
    final cell = fontSize * 2.0;
    final area = size.width * size.height * (1 - bandTop);
    return (area / (cell * cell)).floor().clamp(12, 120);
  }

  /// 文本尺寸（用与绘制完全一致的 style，避免落位与实画错位）
  static (double, double) measure(String text, double fontSize) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: styleFor(fontSize)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return (tp.width, tp.height);
  }

  /// 纯字：只有白字 + 字距，**没有 shadows**（用户明确要求去掉发光）
  static TextStyle styleFor(double fontSize) => TextStyle(
        fontFamily: 'SmileySans',
        fontWeight: FontWeight.bold,
        fontSize: fontSize,
        height: 1.0,
        letterSpacing: -0.02 * fontSize,
        color: Colors.white.withValues(alpha: 0.92),
      );
}

/// 显示层：把 [PitchScatterController.words] 画满整屏。
///
/// 刻意不做任何动画（不淡入、不上浮）：字是「出现」而不是「蹦出来」。
class PitchScatter extends StatelessWidget {
  const PitchScatter({super.key, required this.controller});

  final PitchScatterController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.words.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: SizedBox.expand(
        child: Stack(
          children: [
            for (final w in controller.words)
              Positioned(
                left: w.x,
                top: w.y,
                child: Text(w.text, style: PitchScatterController.styleFor(w.size)),
              ),
          ],
        ),
      ),
    );
  }
}
