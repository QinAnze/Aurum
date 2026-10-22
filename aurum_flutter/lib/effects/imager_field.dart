/// Aurum · 声像颗粒场（立体声宽度的可视化）。
///
/// 读法：**圆心 = 完全单声道，越往外的圈 = 声像越宽**（Ozone Imager 那一套）。
///
/// 它不是"把点搬到声像数值所在的位置"，而是一代一代的尘点：
///  - 每颗点从**圆心附近出生**，寿命 0.55~1.1s
///  - 生长期向外飘：声像越宽推得越快、能跑到越外圈
///  - 老的点在寿命末尾淡出消失，同一时刻有新点从中心冒出来 ——
///    任何时刻屏上都是"新旧混在一起"，所以看得出方向，又不会像一根指针
///  - 每颗点都带简化版 **boids**（对齐 / 凝聚 / 分离），成团地游而不是直线射出
///
/// 性能：粒子数 [kCount]、邻居采样 [kNeighbors]、扇区 [kBins] 三个参数
/// 决定开销；绘制走 [ImagerPainter] 的分档批量画（见那边的注释）。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show PointMode;

import 'package:flutter/material.dart';

class ImagerParticle {
  /// 相对封面中心的位置，**归一化**（1.0 = 最外圈 maxRadius）
  double x = 0;
  double y = 0;

  /// 归一化速度（单位/秒）
  double vx = 0;
  double vy = 0;

  /// 每帧回写的极坐标（绘制、测试用）
  double radius = 0;
  double angle = 0;

  /// 年龄 / 寿命（秒）
  double age = 0;
  double life = 1;

  /// 当前的淡入淡出系数 0..1（由 tick 算好，绘制层只读）
  double alpha = 0;

  /// 点半径（px）
  double dot = 1.5;

  /// 亮度系数（0.5..1）
  double gain = 1;

  /// 个体脾气：受力与限速的差异来源，让群体不整齐
  double temper = 1;
}

class ImagerFieldController {
  /// 粒子集合
  final List<ImagerParticle> dots = [];

  /// 粒子数量。生命周期让大量点在中心附近"刚出生"，所以不用堆到 700
  /// 也有密度感；460 是密度与开销的折中。
  static const int kCount = 460;

  /// 中心（封面中心；封面还没布局时退回画布中心）
  Offset center = Offset.zero;

  /// 最大扩散半径（px）
  double maxRadius = 1;

  /// 当前的声像宽度（0..1），由 VizController 每帧灌入
  double width = 0;

  final math.Random _rng = math.Random();

  /* ---------------- boids 参数 ---------------- */

  static const double _kMaxSpeedLo = 0.20;
  static const double _kMaxSpeedHi = 1.05;
  static const double _kSepR = 0.05;
  static const double _kAlignR = 0.13;

  /// 每帧最多跟几个邻居比。3 个就够形成群落感，7 个是纯浪费。
  static const int _kNeighbors = 3;

  /// 扇区数量（24 个 = 每个 15°，密度足够又不至于每桶只有一两个点）
  static const int _kBins = 24;

  /// 复用的分桶，避免每帧新建 List
  final List<List<int>> _bins =
      List.generate(_kBins, (_) => <int>[], growable: false);

  /* ---------------- 绘制批量缓冲 ---------------- */

  /// 透明度分档：一个档位一次 drawRawPoints
  static const int alphaBuckets = 6;
  /// 点半径分档
  static const int sizeBuckets = 2;

  /// 预分配的坐标缓冲（每档最多 kCount 个点，x/y 交错）
  final List<Float32List> pointBufs = List.generate(
    alphaBuckets * sizeBuckets,
    (_) => Float32List(kCount * 2),
  );

  /// 每档当前写入的浮点数个数（2 × 点数）
  final List<int> pointLens = List.filled(alphaBuckets * sizeBuckets, 0);

  /// 每档一支预建好的画笔（只有颜色逐帧改，避免每帧 new Paint）
  final List<Paint> dotPaints = List.generate(
    alphaBuckets * sizeBuckets,
    (i) => Paint()
      ..style = PaintingStyle.fill
      ..strokeCap = StrokeCap.round
      ..strokeWidth = (i % sizeBuckets) == 0 ? 1.6 : 2.7,
  );

  /// 视口或中心变化时调用（幂等）
  void configure(Size viewport, Offset? coverCenter) {
    if (viewport.isEmpty) return;
    center = coverCenter ?? Offset(viewport.width / 2, viewport.height / 2);
    // 扩散半径取短边的一大半：能明显超出封面圆，但不会顶到面板边缘
    maxRadius = viewport.shortestSide * 0.62;
    if (dots.isEmpty) _seed();
  }

  void _seed() {
    dots.clear();
    for (var i = 0; i < kCount; i++) {
      final p = ImagerParticle();
      _born(p);
      dots.add(p);
    }
    // 预热：否则第一帧所有点都挤在圆心、像一颗粒子炸开。
    // 一次性跑 1.5 秒，之后就永远是"各年龄段混着"的稳态。
    for (var i = 0; i < 90; i++) {
      _step(1 / 60, 0.5);
    }
  }

  /// 出生 / 重生：位置贴近圆心，随机方向给一点初速
  void _born(ImagerParticle p) {
    final a = _rng.nextDouble() * math.pi * 2;
    // 出生点贴着圆心（0.09 以内）—— 这就是"新的从中间出来"
    final r = _rng.nextDouble() * 0.09;
    p.x = math.cos(a) * r;
    p.y = math.sin(a) * r;
    final sp = 0.08 + _rng.nextDouble() * 0.10 + width * 0.30;
    final dir = a + (_rng.nextDouble() - 0.5) * 0.9;
    p.vx = math.cos(dir) * sp;
    p.vy = math.sin(dir) * sp;
    p.age = 0;
    p.life = 0.55 + _rng.nextDouble() * 0.55;
    p.alpha = 0;
    p.dot = 0.9 + _rng.nextDouble() * 1.5;
    p.gain = 0.5 + _rng.nextDouble() * 0.5;
    p.temper = 0.7 + _rng.nextDouble() * 0.6;
    p.radius = r;
    p.angle = a;
  }

  /// 绘制时的可达半径系数：单声道收成中心一小团，最宽时铺满整圈。
  ///
  /// 粒子的**实际行程**已经由推力（± 声像）决定，这里只做一点整体收放，
  /// 让"很窄"的段落更聚拢一点，不至于像雾一样糊住封面。
  double get reachFactor => 0.62 + width * 0.38;

  /// 每帧推进。[dt] 秒，[w] 当前声像宽度 0..1。
  void tick(double dt, double w) {
    if (dots.isEmpty || dt <= 0) return;
    width = w;
    _step(dt, w);
  }

  void _step(double dt, double w) {
    // 1) 按角度分桶，供邻居查询（O(n²) 在几百个点时也可以，但没必要）
    for (final b in _bins) {
      b.clear();
    }
    for (var i = 0; i < dots.length; i++) {
      _bins[_binIndexOf(dots[i])].add(i);
    }

    // 2) 逐个积分
    for (var i = 0; i < dots.length; i++) {
      final p = dots[i];
      p.age += dt;
      if (p.age >= p.life) {
        // 老点到此为止，新点从中心接着来
        _born(p);
        continue;
      }

      var r = math.sqrt(p.x * p.x + p.y * p.y);
      // r ≈ 0 时没有方向，用出生角度兜底（否则会卡在圆心不动）
      final ux = r > 1e-4 ? p.x / r : math.cos(p.angle);
      final uy = r > 1e-4 ? p.y / r : math.sin(p.angle);

      // ---- 向外：声像越宽推得越猛（"宽就往外蹦"） ----
      final push = 0.45 + w * 1.55;
      var ax = ux * push * p.temper;
      var ay = uy * push * p.temper;

      // ---- 轻微切向：整团绕中心流动，不像烟花一样纯放射 ----
      ax += -uy * 0.45 * p.temper;
      ay += ux * 0.45 * p.temper;

      // ---- 软边界：接近外圈就回拉，避免堆成一圈虚线 ----
      if (r > 0.90) {
        final k = (r - 0.90) * 8;
        ax -= ux * k;
        ay -= uy * k;
      }

      // ---- boids ----
      final bin = _bins[_binIndexOf(p)];
      final n = bin.length;
      if (n > 1) {
        var sepX = 0.0, sepY = 0.0;
        var cohX = 0.0, cohY = 0.0;
        var aliX = 0.0, aliY = 0.0;
        var cnt = 0;
        for (var k = 1; k <= _kNeighbors; k++) {
          final j = bin[(i * 7 + k * 11) % n];
          if (j == i) continue;
          final q = dots[j];
          final dx = q.x - p.x;
          final dy = q.y - p.y;
          final d2 = dx * dx + dy * dy;
          if (d2 > _kAlignR * _kAlignR) continue;
          cnt++;
          cohX += q.x;
          cohY += q.y;
          aliX += q.vx;
          aliY += q.vy;
          if (d2 < _kSepR * _kSepR) {
            final inv2 = 1 / math.max(d2, 1e-5);
            sepX -= dx * inv2 * 0.004;
            sepY -= dy * inv2 * 0.004;
          }
        }
        if (cnt > 0) {
          ax += (cohX / cnt - p.x) * 0.9;
          ay += (cohY / cnt - p.y) * 0.9;
          ax += (aliX / cnt - p.vx) * 1.9;
          ay += (aliY / cnt - p.vy) * 1.9;
          ax += sepX;
          ay += sepY;
        }
      }

      // ---- 限速 + 阻尼 ----
      p.vx += ax * dt;
      p.vy += ay * dt;
      final damping = 1 - 1.3 * dt;
      p.vx *= damping;
      p.vy *= damping;
      final cap = _kMaxSpeedLo + w * (_kMaxSpeedHi - _kMaxSpeedLo);
      final sp = math.sqrt(p.vx * p.vx + p.vy * p.vy);
      if (sp > cap) {
        final k = cap / sp;
        p.vx *= k;
        p.vy *= k;
      }

      p.x += p.vx * dt;
      p.y += p.vy * dt;
      r = math.sqrt(p.x * p.x + p.y * p.y);

      // 飞出最外圈就让它"死"在边界外，而不是弹回来
      if (r > 1.08) {
        _born(p);
        continue;
      }

      // ---- 淡入淡出：出生 16% 淡入，寿命过半后开始淡出 ----
      final t = p.age / p.life;
      p.alpha = t < 0.16
          ? t / 0.16
          : (t > 0.52 ? ((1 - t) / 0.48).clamp(0.0, 1.0) : 1.0);

      p.radius = r;
      p.angle = math.atan2(p.y, p.x);
    }
  }

  /// 按**当前位置**算扇区（不要用上一帧回写的 [ImagerParticle.angle]）
  int _binIndexOf(ImagerParticle p) {
    var a = math.atan2(p.y, p.x);
    if (a < 0) a += math.pi * 2;
    return ((a / (math.pi * 2)) * _kBins).floor() % _kBins;
  }

  void reset() {
    dots.clear();
    width = 0;
  }
}

/// 显示层：把颗粒按透明度 / 半径分档批量画出去。
class ImagerField extends StatelessWidget {
  const ImagerField({super.key, required this.controller});

  final ImagerFieldController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.dots.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: CustomPaint(
        painter: ImagerPainter(controller),
        size: Size.infinite,
      ),
    );
  }
}

class ImagerPainter extends CustomPainter {
  ImagerPainter(this.controller);

  final ImagerFieldController controller;

  /// 灰色：深色背景上用低透明度白，看起来就是「灰」
  static const Color grey = Color(0xFFC3C9D4);

  @override
  void paint(Canvas canvas, Size size) {
    final dots = controller.dots;
    if (dots.isEmpty) return;

    final c = controller.center;
    final reach = controller.maxRadius * controller.reachFactor;
    // 整体浓度跟宽度走：单声道时只是几点微光，宽时整层亮起来
    // 生命周期让每颗点有一半时间在淡入淡出，整体比常亮版本暗，
    // 所以基础亮度给得比之前高一点
    final base = 0.30 + controller.width * 0.50;

    const ab = ImagerFieldController.alphaBuckets;
    const sb = ImagerFieldController.sizeBuckets;
    final bufs = controller.pointBufs;
    final lens = controller.pointLens;
    for (var i = 0; i < lens.length; i++) {
      lens[i] = 0;
    }

    // 分档：逐点 drawCircle 在几百个点时是主要开销（每点一条独立绘制指令），
    // 按 (透明度 × 半径) 分 12 档批量画，就只剩 12 次 drawRawPoints。
    for (final p in dots) {
      final a = p.alpha * p.gain;
      if (a <= 0.02) continue;
      final bi = (a * (ab - 1)).round().clamp(0, ab - 1);
      final k = bi * sb + (p.dot > 1.9 ? 1 : 0);
      final buf = bufs[k];
      final n = lens[k];
      if (n + 2 > buf.length) continue;
      buf[n] = c.dx + p.x * reach;
      buf[n + 1] = c.dy + p.y * reach;
      lens[k] = n + 2;
    }

    for (var k = 0; k < bufs.length; k++) {
      final n = lens[k];
      if (n == 0) continue;
      final bi = k ~/ sb;
      final paint = controller.dotPaints[k]
        ..color = grey.withValues(
          alpha: (base * (bi + 1) / ab).clamp(0.0, 1.0),
        );
      canvas.drawRawPoints(
        PointMode.points,
        Float32List.view(bufs[k].buffer, 0, n),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(ImagerPainter old) => true;
}
