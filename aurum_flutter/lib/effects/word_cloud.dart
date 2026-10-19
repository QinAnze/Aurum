/// Aurum · 魔法书词云（移植自原版 index.html 的 bgCloud 体系）。
/// 生命周期：rise(重力减速上升 850ms) → hold(停留 4.2~8s) → fall(自由落体 1150ms)；
/// 换行不硬清场（cloudDropAll 错落坠落）；碰撞检测 + 封面圆禁区；
/// 句末最后两个词显著放大；按音节节奏出场；极克制的描边光（仅超频）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../lyrics/lyrics_engine.dart' show countSyllables;
import '../../models.dart';

const int kRiseMs = 850;
const int kFallMs = 1150;
const double kPadding = 6;

/// 词云运行环境（每帧由 VizController 注入）
class CloudEnv {
  const CloudEnv({
    required this.on,
    required this.lyrics,
    required this.size,
    required this.colors,
    required this.overclock,
    required this.climax,
    this.coverRect,
  });

  final bool on;
  final List<LyricLine> lyrics;
  final Size size;
  final List<Color> colors;
  final bool overclock;
  final double climax;
  /// 封面圆外接矩形（视口坐标；落在圆内的词会被封面挡住 → 禁区）
  final Rect? coverRect;
}

class CloudWord {
  CloudWord({
    required this.text,
    required this.x,
    required this.y,
    required this.size,
    required this.vertical,
    required this.color,
    required this.t0,
    required this.startY,
    required this.holdMs,
  });

  String text;
  double x, y, size;
  bool vertical;
  Color color;
  String phase = 'rise'; // rise | hold | fall
  double t0; // ms（墙钟）
  double startY;
  double holdMs;
  double fallFrom = 0;

  /// 这一颗词的坠落时长（ms）。正常换行用 [kFallMs]；相位切走时
  /// （进入纯乐器段）用更短的值，让它赶在背景平铺开始前落完。
  double fallMs = kFallMs.toDouble();

  TextPainter? _painter; // 横排
  List<TextPainter>? _chars; // 竖排逐字
  int _styleKey = -1; // (alpha,blur) 量化缓存键，未变则不重建文本布局
}

class _Rect {
  const _Rect(this.x, this.y, this.w, this.h);
  final double x, y, w, h;
}

class WordCloudController {
  final List<CloudWord> words = [];
  final Stopwatch clock = Stopwatch()..start();
  final math.Random _rng = math.Random();
  final TextPainter _measure = TextPainter(textDirection: TextDirection.ltr);

  List<_Rect> _placed = [];
  List<String> _chars = const [];
  int _line = -1;
  int _revealed = 0;
  List<double> _spawnTimes = const [];

  bool get hasActive => words.isNotEmpty;

  double get nowMs => clock.elapsedMilliseconds.toDouble();

  /// 让屏上现有的词立刻错落坠落（相位离开歌词段时用）。
  ///
  /// 与 [reset] 的区别：这里是**落下去**（1 秒内的坠落动画），
  /// 而 reset 是硬清空。`fallMs` 可以调短，好让位给背景平铺。
  void dropCurrent({double? fallMs}) => _dropAll(fallMs: fallMs);

  void reset() {
    _placed = [];
    _chars = const [];
    _line = -1;
    _revealed = 0;
    _spawnTimes = const [];
    words.clear();
  }

  /* ---------------- 换行：旧词错落坠落（cloudDropAll） ---------------- */
  void _dropAll({double? fallMs}) {
    final now = nowMs;
    final fs = fallMs ?? kFallMs.toDouble();
    for (final wd in words) {
      if (wd.phase == 'fall') continue;
      if (wd.phase == 'rise') {
        final p = ((now - wd.t0) / kRiseMs).clamp(0.0, 1.0);
        // 当前高度无缝衔接（上升中的词按当前 p 反算）
        wd.fallFrom = wd.y + (wd.startY - wd.y) * math.pow(1 - p, 2);
      } else {
        wd.fallFrom = wd.y;
      }
      wd.phase = 'fall';
      wd.fallMs = fs;
      wd.t0 = now + _rng.nextDouble() * 120; // 错落坠落，不整齐划一
    }
  }

  /* ---------------- 播放进度驱动（cloudTick） ---------------- */
  void tick(double t, CloudEnv env) {
    if (!env.on || env.lyrics.isEmpty) return;
    var idx = -1;
    for (var i = 0; i < env.lyrics.length; i++) {
      if (env.lyrics[i].t <= t) {
        idx = i;
      } else {
        break;
      }
    }
    if (idx < 0) {
      if (_line != -1) _dropAll();
      return;
    }
    if (idx != _line) {
      _line = idx;
      _revealed = 0;
      _placed = [];
      _chars = env.lyrics[idx].tokens; // 预分词缓存
      final t0 = env.lyrics[idx].t;
      final t1 = idx + 1 < env.lyrics.length ? env.lyrics[idx + 1].t : t0 + 4;
      final gap = t1 - t0;
      // 间隔>9s（如中间隔 drop 段）强制 4s 内显示完
      final span = gap > 9 ? 4 : gap * 0.72;
      // 按音节占比分配出场时刻，贴合演唱节奏
      final syl = _chars.map(countSyllables).toList();
      final totalSyl = syl.fold<int>(0, (a, b) => a + b);
      _spawnTimes = [];
      if (totalSyl > 0) {
        var acc = 0;
        for (var k = 0; k < _chars.length; k++) {
          final at = ((acc + syl[k] / 2) / totalSyl) * span;
          _spawnTimes.add(t0 + at);
          acc += syl[k];
        }
      }
      _dropAll();
    }
    if (_chars.isNotEmpty && _spawnTimes.isNotEmpty) {
      final now = nowMs;
      var k = 0;
      while (_revealed < _chars.length && t >= _spawnTimes[_revealed]) {
        _spawn(_chars[_revealed], now + k * 90, _revealed, _chars.length, env);
        _revealed++;
        k++;
      }
    }
  }

  /* ---------------- 生成一个词（cloudSpawn） ---------------- */
  void _spawn(String word, double t0, int idx, int total, CloudEnv env) {
    final w = env.size.width, h = env.size.height;
    if (w <= 0 || h <= 0 || word.trim().isEmpty) return;
    final vertical = _rng.nextDouble() < 0.35;
    var size = 15 + _rng.nextDouble() * math.min(w, h) * 0.12;
    size = math.max(12, math.min(size, math.min(w, h) * 0.2));
    final isLast = total > 0 && idx >= total - 2; // 句末最后两个词：放大
    if (isLast) {
      size = math.min(w, h) * (0.18 + _rng.nextDouble() * 0.12);
      // 超出画布则收缩至可容纳（绝不丢弃）
      var fit = size;
      for (var s = 0; s < 60; s++) {
        final (tw, th) = _measureWord(word, vertical, fit);
        if (tw < w && th < h) break;
        fit *= 0.92;
        if (fit < 12) {
          fit = 12;
          break;
        }
      }
      size = fit;
    }

    // 封面圆（视口坐标）：词云画布满屏，坐标空间 == 视口坐标空间
    var haveCover = false;
    var coverCx = 0.0, coverCy = 0.0, coverR = 0.0;
    final cr = env.coverRect;
    if (cr != null && cr.width > 1) {
      haveCover = true;
      coverCx = cr.left + cr.width / 2;
      coverCy = cr.top + cr.height / 2;
      coverR = cr.width / 2 + 14; // 圆本身 + 边距（同时避开紧贴的频谱环）
    }

    final colors = env.colors;
    for (var attempt = 0; attempt < 200; attempt++) {
      final (tw, th) = _measureWord(word, vertical, size);
      if (tw >= w || th >= h) return;
      final x = math.max(
          kPadding, math.min(kPadding + _rng.nextDouble() * (w - tw - 2 * kPadding), w - tw - kPadding));
      final y = math.max(
          kPadding, math.min(kPadding + _rng.nextDouble() * (h - th - 2 * kPadding), h - th - kPadding));
      if (x < 0 || y < 0) continue;
      final hit = _placed.any((r) => x < r.x + r.w && x + tw > r.x && y < r.y + r.h && y + th > r.y);
      if (hit) continue;
      if (haveCover) {
        final nx = math.max(x, math.min(coverCx, x + tw));
        final ny = math.max(y, math.min(coverCy, y + th));
        final dx = coverCx - nx, dy = coverCy - ny;
        if (dx * dx + dy * dy < coverR * coverR) continue;
      }
      _place(word, x, y, tw, th, size, vertical, colors, t0, h);
      return;
    }

    // 兜底：最后两词务必显示——碰撞 200 次仍失败则忽略碰撞强制落位（仍避开封面圆）
    if (isLast) {
      final (tw, th) = _measureWord(word, vertical, size);
      if (tw < w && th < h) {
        for (var a = 0; a < 60; a++) {
          final x = math.max(kPadding,
              math.min(kPadding + _rng.nextDouble() * (w - tw - 2 * kPadding), w - tw - kPadding));
          final y = math.max(kPadding,
              math.min(kPadding + _rng.nextDouble() * (h - th - 2 * kPadding), h - th - kPadding));
          var okCover = true;
          if (haveCover) {
            final nx = math.max(x, math.min(coverCx, x + tw));
            final ny = math.max(y, math.min(coverCy, y + th));
            final dx = coverCx - nx, dy = coverCy - ny;
            if (dx * dx + dy * dy < coverR * coverR) okCover = false;
          }
          if (okCover) {
            _place(word, x, y, tw, th, size, vertical, colors, t0, h);
            return;
          }
        }
      }
    }
  }

  (double, double) _measureWord(String word, bool vertical, double size) {
    _measure.text = TextSpan(
      text: word,
      style: TextStyle(
        fontFamily: 'SmileySans',
        fontWeight: FontWeight.bold,
        fontSize: size,
      ),
    );
    _measure.layout();
    final tw = _measure.width + kPadding * 2;
    final th = (vertical ? word.length * (size + 2) : size) + kPadding * 2;
    return (tw, th);
  }

  void _place(String word, double x, double y, double tw, double th, double size,
      bool vertical, List<Color> colors, double t0, double canvasH) {
    _placed.add(_Rect(x, y, tw, th));
    words.add(CloudWord(
      text: word,
      x: x,
      y: y,
      size: size,
      vertical: vertical,
      color: colors[_rng.nextInt(colors.length)],
      t0: t0,
      startY: canvasH + 20 + _rng.nextDouble() * 60,
      holdMs: 4200 + _rng.nextDouble() * 3800,
    ));
  }
}

/* ---------------- 配色：强制「白 / 浅色」，杜绝灰字 ---------------- */
final math.Random _colorRng = math.Random();

/// 封面色 → HSL 亮度拉到 ~0.86、饱和度保底 0.45（浅而鲜艳）
Color lightColor(Color c) {
  final hsl = HSLColor.fromColor(c);
  final l = 0.86 + (_colorRng.nextDouble() * 0.07 - 0.035); // 0.825 ~ 0.895
  final s = math.min(1.0, math.max(hsl.saturation, 0.45));
  return HSLColor.fromAHSL(1, hsl.hue, s, l).toColor();
}

/// 固定浅色调（白 + 浅粉/蓝/绿/黄/紫）
const List<Color> _kCloudPastels = [
  Color(0xFFFFFFFF),
  Color(0xFFFFEEF6),
  Color(0xFFEEF4FF),
  Color(0xFFF0FFF0),
  Color(0xFFFFF7E6),
  Color(0xFFF3E8FF),
];

List<Color> cloudColors(List<Color> palette) =>
    [...palette.map(lightColor), ..._kCloudPastels];

/* ---------------- 生命周期推进（advance） ---------------- */
extension WordCloudAdvance on WordCloudController {
  /// 推进相位、移除坠完的词；返回是否还有活词
  bool advance() {
    final now = nowMs;
    for (var i = words.length - 1; i >= 0; i--) {
      final wd = words[i];
      if (wd.phase == 'rise') {
        if ((now - wd.t0) / kRiseMs >= 1) {
          wd.phase = 'hold';
          wd.t0 = now;
        }
      } else if (wd.phase == 'hold') {
        if (now - wd.t0 > wd.holdMs) {
          wd.phase = 'fall';
          wd.t0 = now;
          wd.fallFrom = wd.y;
        }
      } else {
        if ((now - wd.t0) / wd.fallMs >= 1) {
          words.removeAt(i);
        }
      }
    }
    return words.isNotEmpty;
  }
}

/* ---------------- 词云 painter ---------------- */
class WordCloudPainter extends CustomPainter {
  const WordCloudPainter({
    required this.controller,
    required this.climax,
    required this.overclock,
  });

  final WordCloudController controller;
  final double climax;
  final bool overclock;

  @override
  void paint(Canvas canvas, Size size) {
    final now = controller.nowMs;
    final h = size.height;
    for (final wd in controller.words) {
      double y;
      double alpha = 1;
      if (wd.phase == 'rise') {
        final p = (now - wd.t0) / kRiseMs;
        if (p < 0) continue; // 排队等待入场
        if (p >= 1) {
          y = wd.y;
        } else {
          // 上升段：ease-out quad = 恒定减速度，等同重力上抛
          y = wd.y + (wd.startY - wd.y) * math.pow(1 - p, 2);
          alpha = math.min(1, p * 2.2);
        }
      } else if (wd.phase == 'hold') {
        y = wd.y;
        if (now - wd.t0 > wd.holdMs) {
          // advance() 未及时推进时兜底转换
          final p = (now - wd.t0 - wd.holdMs) / wd.fallMs;
          if (p >= 1) continue;
          y = wd.y + (math.pow(p, 2) as double) * (h + 40 - wd.y);
          alpha = 1 - (math.pow(p, 2.2) as double);
        }
      } else {
        // 坠落段：ease-in quad = 自由落体加速，淡出到底消失
        final p = (now - wd.t0) / wd.fallMs;
        if (p < 0) {
          y = wd.fallFrom;
        } else if (p >= 1) {
          continue;
        } else {
          y = wd.fallFrom + (math.pow(p, 2) as double) * (h + 40 - wd.fallFrom);
          alpha = 1 - (math.pow(p, 2.2) as double);
        }
      }
      _paintWord(canvas, wd, y, alpha);
    }
  }

  void _paintWord(Canvas canvas, CloudWord wd, double y, double alpha) {
    // 极克制的描边光，仅让字略微浮起，不糊字（仅超频）
    final blur = overclock ? wd.size * 0.10 * (0.5 + climax * 0.35) : 0.0;
    final a = (alpha * 0.92).clamp(0.0, 1.0);
    // (alpha,blur) 量化缓存：未变则不重建文本布局
    final key = ((a * 24).round() << 12) | (blur * 4).round().clamp(0, 4095);
    if (wd._styleKey != key) {
      wd._styleKey = key;
      final style = TextStyle(
        fontFamily: 'SmileySans',
        fontWeight: FontWeight.bold,
        fontSize: wd.size,
        color: wd.color.withValues(alpha: a),
        shadows:
            blur > 0.5 ? [Shadow(color: wd.color, blurRadius: blur)] : null,
      );
      if (wd.vertical) {
        wd._chars = List.generate(wd.text.length, (i) {
          return TextPainter(
            text: TextSpan(text: wd.text[i], style: style),
            textDirection: TextDirection.ltr,
          )..layout();
        });
      } else {
        wd._painter = TextPainter(
          text: TextSpan(text: wd.text, style: style),
          textDirection: TextDirection.ltr,
        )..layout();
      }
    }
    if (wd.vertical) {
      final chars = wd._chars;
      if (chars == null) return;
      for (var ci = 0; ci < chars.length; ci++) {
        chars[ci].paint(
            canvas, Offset(wd.x + kPadding, y + kPadding + ci * (wd.size + 2)));
      }
    } else {
      wd._painter?.paint(canvas, Offset(wd.x + kPadding, y + kPadding));
    }
  }

  /// 词的位置/相位每帧都在变（CloudWord 是可变对象，父子 painter 共享同一份
  /// controller），按字段比较无法反映变化 —— 必须恒重绘，否则词云只在 climax
  /// 变化的那一帧跳一下，看起来像卡住的幻灯片。
  @override
  bool shouldRepaint(WordCloudPainter old) => true;
}
