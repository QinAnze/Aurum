/// 音高散落（非歌词段 / 超长句后半段专用）。
///
/// 与 [PitchBadge] 是**两套互不相干的视觉**，按相位二选一：
///  - 人声段（歌词）：封面中央单个字母，从下升起 + 发光 —— 见 pitch_badge.dart
///  - 乐器段（>8s 间隙 / 超长句 >8s 的部分）：**整块背景**随机散落，
///    每换一个音就多一个字母，直接出现（无位移、无淡入、无光晕），
///    放满就清空重来
///
/// 落点：整个视口（含顶部），纯随机取点 + 矩形避让。之前只在下半屏的
/// 一条横带里按列切片排，看着像「贴了一条字幕」，不是背景。
///
/// 每个字母独立随机的三件事：
///  - **字号**：分三档 —— 小（0.45–0.85 基准）/ 中（1.0–1.9）/ 巨（2.8–5.2）。
///    巨型字是整片背景的视觉锚点，刻意只占少数（8%）。
///  - **方向**：约 1/4 竖排（逐字换行），其余横排。
///  - **颜色**：从封面取色板里随机挑，再各自微调亮度。
///
/// 字体用打包在 `assets/` 里的 **EB Garamond**（衬线）：巨型字用 Regular，
/// 细衬线在大字号下更耐看；小字用 SemiBold，保证小尺寸下也清楚。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 一个已经落位的音高字
class ScatterWord {
  ScatterWord({
    required this.note,
    required this.x,
    required this.y,
    required this.size,
    required this.color,
    required this.width,
    required this.height,
    this.vertical = false,
    this.giant = false,
  });

  /// 原始音名（'C#4'）
  final String note;
  final double x;
  final double y;
  final double size;
  final Color color;

  /// 落位时量出的文本尺寸。渲染时必须用它约束 Text：只给 left/top 的话，
  /// Text 的可用宽度是「视口宽 − x」，靠右的字会被挤成自动换行，
  /// 位置与避让矩形全对不上（实测小字会压在大字上、右侧还会被裁掉）。
  final double width;
  final double height;

  /// true = 竖排（逐字换行）
  final bool vertical;

  /// true = 巨型档（用细衬线的 Regular，透明度更低）
  final bool giant;

  /// 实际绘制用的文本：竖排时逐字换行，升号 `#` 跟在前一个音名后
  /// （'C#4' → 'C#\n4'），否则会读成「C / 井号 / 4」三行，中间那个符号很怪。
  String get text =>
      vertical ? PitchScatterController.verticalTextOf(note) : note;
}

class _Rect {
  const _Rect(this.x, this.y, this.w, this.h);
  final double x, y, w, h;

  /// [ox],[oy],[ow],[oh] 是候选矩形（要放的新字）。
  ///
  /// 第二、四个条件必须用 `ow`/`oh`（候选自己的宽高）。这里一度写成了
  /// `ox + w` / `oy + h`（已放置矩形的宽高）—— 候选比已有字**更宽**时，
  /// 判定反而更容易通过，大字就会直接压在小字上，而测试只查位置、
  /// 查不出这种重叠。
  bool hits(double ox, double oy, double ow, double oh) =>
      ox < x + w && ox + ow > x && oy < y + h && oy + oh > y;
}

/// 落位难度：巨型字要试更多次才找得到空位
enum _Tier { small, medium, giant }

/// 纯数据控制器：由 [VizController] 逐帧驱动，widget 只负责画。
class PitchScatterController {
  /// 已落位的字母（按放置顺序排列，画的时候可以整层重建）
  final List<ScatterWord> words = [];

  /// 字体族：assets/ 里打包的衬线体（见 pubspec.yaml）
  static const String fontFamily = 'AurumSerif';

  /// 竖排概率
  static const double verticalChance = 0.26;

  /// 巨型字概率
  static const double giantChance = 0.08;

  /// 铺到多满就清屏重来。
  ///
  /// 这个数**不是**眼睛看到的「满度」：它算的是每个字外接矩形的面积，
  /// 而字形周围大半是空白（一个 'C#6' 的框里墨迹只占四成）。
  /// 0.42 实测对应视觉上七成多满，正好是用户要的「75% 就清」。
  /// 之前写 0.60 时视觉压到八九成，看着就是「铺爆了」。
  static const double maxCoverage = 0.42;

  /// 字数上限。光看面积不够：同一档面积里如果小字抽得多，能塞进
  /// 一百二三十个碎字，观感比「大字少字」的一轮挤得多。用字数钉住上限。
  static const int maxWords = 100;

  /// 基准字号占短边的比例
  static const double baseRatio = 0.045;

  /// 竖排文本：逐字换行，升号 `#` 并到前一个音名后面（'C#4' → 'C#\n4'）
  static String verticalTextOf(String note) {
    final lines = <String>[];
    for (final ch in note.split('')) {
      if (ch == '#' && lines.isNotEmpty) {
        lines[lines.length - 1] = '${lines.last}#';
      } else {
        lines.add(ch);
      }
    }
    return lines.join('\n');
  }

  final math.Random _rng = math.Random();
  List<_Rect> _placed = [];
  double _coverage = 0;

  /// 本轮（清屏后）已经放过几个字。用它在每一轮开头先立一个巨型字：
  /// 巨型字只占 8% 概率，一轮铺满可能一个都没抽到，背景就平了。
  int _sinceClear = 0;

  /// 当前取色板（来自封面采样）；空则退回白色
  List<Color> _palette = const [];

  Size _size = Size.zero;

  /// 当前视口（未 layout 过时是 Size.zero）
  Size get viewport => _size;

  bool get isEmpty => words.isEmpty;

  /// 更新取色板（封面色变化时由外部每帧灌一次，不会重建已落位的字）
  void setPalette(List<Color> colors) {
    if (identical(colors, _palette)) return;
    if (colors.length == _palette.length) {
      var same = true;
      for (var i = 0; i < colors.length; i++) {
        if (colors[i] != _palette[i]) {
          same = false;
          break;
        }
      }
      if (same) return;
    }
    _palette = List<Color>.unmodifiable(colors);
  }

  /// 视口尺寸变化（或首帧）时调用
  void layout(Size size) {
    if (size == _size) return;
    _size = size;
  }

  /// 清空（进入人声段 / 切歌 / 关特效 / 铺满）
  void clear() {
    if (words.isEmpty) return;
    words.clear();
    _placed = [];
    _coverage = 0;
    _sinceClear = 0;
  }

  /// 每检测到一个新音高调用一次：[rnd] 外部注入，保证测试可确定性。
  ///
  /// 返回 false 表示这次没放上去。两种 false 要分开看：
  ///  - **铺满了**（面积/字数到顶）→ 清空，下一帧从空屏重来；
  ///  - **只是这个字塞不进缝**（还没满，但它是巨型字）→ 保留已铺好的背景，
  ///    这次少一个音而已。早期不区分，结果一个大字放不下就把整屏清掉，
  ///    背景永远长不到铺满的样子。
  bool spawn(String note, {math.Random? rnd}) {
    final r = rnd ?? _rng;
    final size = _size;
    if (size.isEmpty || note.isEmpty) return false;
    layout(size);
    if (_isFull()) {
      clear();
      return false;
    }

    var tier = _pickTier(r);
    var ok = _tryPlace(note, tier, r);
    // 巨型字挤不进去时降一档再试：宁可这次小一点，也不要空着。
    if (!ok && tier == _Tier.giant) {
      ok = _tryPlace(note, _Tier.medium, r);
    }
    if (ok) return true;
    // 这一刻已经满了（放这个字会超）→ 清空重来
    if (_isFull()) clear();
    return false;
  }

  /// 是否已经铺满：面积或字数到了上限
  bool _isFull() {
    if (_size.isEmpty) return false;
    if (words.length >= maxWords) return true;
    return _coverage >= _size.width * _size.height * maxCoverage * 0.96;
  }

  _Tier _pickTier(math.Random r) {
    // 每一轮的头两个字先放巨型字：屏幕空着，一定塞得下，
    // 背景一开始就有锚点，而不是先铺满小字再被大字挤开。
    if (_sinceClear < 2) return _Tier.giant;
    final v = r.nextDouble();
    if (v < giantChance) return _Tier.giant;
    if (v < giantChance + 0.34) return _Tier.medium;
    return _Tier.small;
  }

  /// 按档位抽字号（短边为基准，跟窗口一起缩放）
  ///
  /// 三档之间刻意留断档（0.85 → 1.00、1.90 → 2.80）：连续分布只会得到
  /// 一堆「差不多大」的字，看起来还是均匀。断档才有大小节奏。
  static double _fontSizeFor(_Tier tier, math.Random r, Size size) {
    final base = math.max(10.0, size.shortestSide * baseRatio);
    return switch (tier) {
      _Tier.small => base * (0.45 + r.nextDouble() * 0.40), // 0.45–0.85
      _Tier.medium => base * (1.00 + r.nextDouble() * 0.90), // 1.00–1.90
      _Tier.giant => base * (3.00 + r.nextDouble() * 2.20), // 3.00–5.20
    };
  }

  /// 竖排的字只剩半个宽，同字号看起来比横排小一截 → 补 1.2 倍
  static const double verticalScale = 1.2;

  bool _tryPlace(String note, _Tier tier, math.Random r) {
    final size = _size;
    final vertical = r.nextDouble() < verticalChance;
    final giant = tier == _Tier.giant;
    final fontSize = _fontSizeFor(tier, r, size) *
        (vertical ? verticalScale : 1.0);
    final text = vertical ? verticalTextOf(note) : note;
    final (tw, th) =
        measure(text, fontSize, vertical: vertical, giant: giant);
    if (tw <= 0 || th <= 0) return false;
    if (tw > size.width - 8 || th > size.height - 8) return false;

    // 铺满了就不再塞：清空重来
    final area = size.width * size.height;
    if (words.length >= maxWords || _coverage + tw * th > area * maxCoverage) {
      return false;
    }

    // 巨型字落位难，多试；小字快速放弃
    final attempts = switch (tier) {
      _Tier.giant => 240,
      _Tier.medium => 90,
      _Tier.small => 50,
    };
    // 边距：衬线的字肩、斜体的伸出会超出 advance width，贴边会被裁掉；
    // 字与字之间也要留一点缝，不然紧贴的衬线看起来像叠在一起。
    const pad = 8.0;
    const margin = 6.0;
    final maxX = math.max(margin, size.width - tw - margin);
    final maxY = math.max(margin, size.height - th - margin);
    for (var i = 0; i < attempts; i++) {
      // 整块背景随机撒：不分区、不分带，顶部与底部机会均等
      final x = margin + r.nextDouble() * (maxX - margin);
      final y = margin + r.nextDouble() * (maxY - margin);
      if (_placed.any(
          (p) => p.hits(x - pad, y - pad, tw + pad * 2, th + pad * 2))) {
        continue;
      }
      _place(note, vertical, giant, x, y, tw, th, fontSize, r);
      return true;
    }
    return false;
  }

  /// 从封面色板里挑一个：色板为空就白色，否则随机挑并在亮度上抖一点，
  /// 免得一堆同色字糊成一片。巨型字压低一点不透明度，当背景而不是墙。
  Color _pickColor(math.Random r, bool giant) {
    final alpha = giant ? 0.80 : 0.93;
    if (_palette.isEmpty) return Colors.white.withValues(alpha: alpha);
    final hsl = HSLColor.fromColor(_palette[r.nextInt(_palette.length)]);
    final l = (hsl.lightness + 0.10 + r.nextDouble() * 0.24).clamp(0.58, 0.95);
    return hsl.withLightness(l.toDouble()).toColor().withValues(alpha: alpha);
  }

  void _place(
    String note,
    bool vertical,
    bool giant,
    double x,
    double y,
    double tw,
    double th,
    double fontSize,
    math.Random r,
  ) {
    words.add(ScatterWord(
      note: note,
      x: x,
      y: y,
      size: fontSize,
      color: _pickColor(r, giant),
      width: tw,
      height: th,
      vertical: vertical,
      giant: giant,
    ));
    _placed.add(_Rect(x, y, tw, th));
    _coverage += tw * th;
    _sinceClear++;
  }

  /// 按屏幕尺寸估一个容量上限（面积控制之外的兜底，测试可读）
  static int computeCapacity(Size size) {
    if (size.isEmpty) return maxWords;
    final base = math.max(10.0, size.shortestSide * baseRatio);
    final cell = base * 1.6;
    final n = (size.width * size.height / (cell * cell)).floor();
    return n.clamp(24, maxWords);
  }

  /// 文本尺寸（用与绘制完全一致的 style，避免落位与实画错位）。
  static (double, double) measure(String text, double fontSize,
      {bool vertical = false, bool giant = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: styleFor(fontSize, giant: giant, vertical: vertical),
      ),
      textDirection: TextDirection.ltr,
      maxLines: vertical ? null : 1,
    )..layout();
    return (tp.width, tp.height);
  }

  /// 纯字：**没有 shadows**（用户明确要求去掉发光）。颜色由每个字自己带。
  ///
  /// 衬线体按字号换权重：巨型字用 Regular（细线在大字号下更好看），
  /// 其余用 SemiBold（小尺寸下笔画才立得住）。竖排行距压到 0.78。
  ///
  /// `inherit: false` 是必须的：默认 true 时会和 Material 的
  /// `DefaultTextStyle` 合并，凭空多出下划线（预览时整片字下面一道黄线）
  /// 以及不同的行高 —— 行高一变，`measure` 量的框就和实际画的框对不上，
  /// 避让失效，字开始互相压。
  static TextStyle styleFor(
    double fontSize, {
    Color? color,
    bool giant = false,
    bool vertical = false,
  }) =>
      TextStyle(
        inherit: false,
        fontFamily: fontFamily,
        fontWeight: giant ? FontWeight.w400 : FontWeight.w600,
        fontSize: fontSize,
        // EB Garamond 的 ascent+descent ≈ 1.2em，竖排要压到 0.78 才紧凑
        height: vertical ? 0.78 : 1.0,
        letterSpacing: vertical ? 0 : -0.01 * fontSize,
        color: color ?? Colors.white.withValues(alpha: 0.93),
        decoration: TextDecoration.none,
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
                // 显式宽高：不给的话 Text 会按「剩余宽度」自动换行
                width: w.width,
                height: w.height,
                child: Text(
                  w.text,
                  textAlign: TextAlign.center,
                  style: PitchScatterController.styleFor(
                    w.size,
                    color: w.color,
                    giant: w.giant,
                    vertical: w.vertical,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
