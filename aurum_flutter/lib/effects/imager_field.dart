/// Aurum · 声像颗粒场（立体声宽度的可视化）。
///
/// 读法：**圆心 = 完全单声道，越往外的圈 = 声像越宽**（Ozone Imager 那一套）。
///
/// 运动是**弹道**而不是"平移到位"：
///  - 声像宽 → 弹簧把点甩向外圈；声像一收，弹簧 + 重力把它们**自己落回来**
///  - 位置不是 lerp 到目标半径，而是力积分：会冲过头、会回落、会绕流
///  - 每颗点有**自己的层位**（[ImagerParticle.layer]），所以是一片雾，
///    不是所有点被拉到同一个半径上排成一圈
///  - 落到内圈（[_floor]）弹一下，反弹速度保底，所以永远是活的
///  - 每颗点还跑简化版 boids（对齐 / 凝聚 / 分离），成团地绕
///
/// 旧版本是"点位 = 声像数值"（每个点平滑移到对应半径），看起来像指针；
/// 再之前的生命周期版是"出生→飘出→淡出→重生"，在 drop 段会因为点全缩在
/// 封面背后而整片看不见。现在封面做成 50% 半透明，点透过去也看得见，
/// 内圈地板因此可以收到封面内侧（视觉上像藏在玻璃后面）。
///
/// 性能：绘制走 [ImagerPainter] 的**分档批量画**（alpha × 半径分桶，
/// `drawRawPoints` 一次画一整桶），逐点 `drawCircle` 是几百次独立绘制调用。
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

  /// 亮度系数（0.5..1）
  double gain = 1;

  /// 个体脾气：受力与限速的差异来源，让群体不整齐
  double temper = 1;

  /// 个体在壳层里的"层位"：0 贴内圈、1 到当前壳层。
  /// 弹簧如果没有个体差，所有点会被拉到**同一个半径**上排成一圈虚线；
  /// 这个字段让整片是雾状分布。
  double layer = 1;
}

class ImagerFieldController {
  /// 粒子集合
  final List<ImagerParticle> dots = [];

  /// 粒子数量：够密才有"声场"的雾面感。
  /// 绘制已经改成批量画（12 次 drawRawPoints），760 点的物理只要 ~0.15ms/帧。
  static const int kCount = 760;

  /// 中心（封面中心；封面还没布局时退回画布中心）
  Offset center = Offset.zero;

  /// 最大扩散半径（px）
  double maxRadius = 1;

  /// 当前的声像宽度（0..1），由 VizController 每帧灌入
  double width = 0;

  /// 内圈地板（归一化半径）。
  ///
  /// 现在允许落在**封面圆内侧**：专辑封面已经做成 50% 半透明，
  /// 点透过去反而更好看（像藏在玻璃后面）。早前封面不透明时，
  /// 点缩进封面就会整片消失 —— 那才是 drop 段看不见点的原因。
  double get floorRadius => _floor;
  double _floor = 0.30;

  final math.Random _rng = math.Random();

  /* ---------------- 物理参数 ---------------- */

  /// 弹簧刚度：把点往"当前声像对应的壳层"拉，力 ∝ 距离，
  /// 所以会冲过、回落，而不是被直接摆到那个半径上。
  /// 刚度太大 = 硬邦邦地贴在壳层上，太小 = 飘忽不落地。
  static const double _kSpring = 2.0;

  /// 恒定向心重力：给"落"一个明确方向（声像收窄时掉得更干脆）
  static const double _kGravity = 0.25;

  /// 壳层位置（归一化半径）：单声道贴着内圈，最宽时到外圈附近。
  /// 上界刻意不到 1.0 —— 常数推力会顶到墙上，弹簧模型则有平衡点。
  static const double _kShellLo = 0.10;
  static const double _kShellHi = 0.85;

  /// 切向扰动：让整团绕中心流动，而不是纯放射
  static const double _kSwirl = 0.40;

  /// 内圈反弹的保底径向速度（否则会停在地板上不动）
  static const double _kHop = 0.20;

  /// 反弹系数
  static const double _kRestFloor = 0.50;
  static const double _kRestWall = 0.35;

  static const double _kMaxSpeed = 1.10;

  /* ---------------- boids 参数 ---------------- */

  static const double _kSepR = 0.05;
  static const double _kAlignR = 0.13;

  /// 每帧最多跟几个邻居比：3 个就够形成群落感
  static const int _kNeighbors = 3;

  /// 扇区数量（24 个 = 每 15° 一桶）
  static const int _kBins = 24;

  final List<List<int>> _bins =
      List.generate(_kBins, (_) => <int>[], growable: false);

  /* ---------------- 绘制批量缓冲 ---------------- */

  static const int alphaBuckets = 6;
  static const int sizeBuckets = 2;

  final List<Float32List> pointBufs = List.generate(
    alphaBuckets * sizeBuckets,
    (_) => Float32List(kCount * 2),
  );

  final List<int> pointLens = List.filled(alphaBuckets * sizeBuckets, 0);

  final List<Paint> dotPaints = List.generate(
    alphaBuckets * sizeBuckets,
    (i) => Paint()
      ..style = PaintingStyle.fill
      ..strokeCap = StrokeCap.round
      ..strokeWidth = (i % sizeBuckets) == 0 ? 2.0 : 3.2,
  );

  /// 视口或中心变化时调用（幂等）。
  ///
  /// [coverRadius] 是封面圆的半径（px）：内圈地板按它的 0.62 倍放，
  /// 落在封面内侧 —— 封面半透明，点透过去看得见。
  void configure(Size viewport, Offset? coverCenter, {double coverRadius = 0}) {
    if (viewport.isEmpty) return;
    center = coverCenter ?? Offset(viewport.width / 2, viewport.height / 2);
    // 扩散半径取短边的一大半：能明显超出封面圆，但不会顶到面板边缘
    maxRadius = viewport.shortestSide * 0.62;
    if (coverRadius > 0) {
      // 0.62 = 位于封面圆内侧：单声道时会缩成封面里的一小圈，
      // 透过 50% 半透明的封面仍看得见
      _floor = (coverRadius / maxRadius * 0.62).clamp(0.04, 0.82);
    }
    if (dots.isEmpty) _seed();
  }

  void _seed() {
    dots.clear();
    for (var i = 0; i < kCount; i++) {
      final p = ImagerParticle();
      // 开方分布：中段密、外圈疏，像声场
      final r = _floor + (1 - _floor) * math.sqrt(_rng.nextDouble());
      final a = _rng.nextDouble() * math.pi * 2;
      final tangential = 0.15 + _rng.nextDouble() * 0.35;
      p.x = math.cos(a) * r;
      p.y = math.sin(a) * r;
      p.vx = -math.sin(a) * tangential;
      p.vy = math.cos(a) * tangential;
      p.radius = r;
      p.angle = a;
      p.gain = 0.5 + _rng.nextDouble() * 0.5;
      p.temper = 0.7 + _rng.nextDouble() * 0.6;
      // 开方 → 靠内层的点多一些，外圈稀，像声场的衰减
      p.layer = math.sqrt(_rng.nextDouble());
      dots.add(p);
    }
  }

  /// 绘制时的可达半径系数：窄时整体收一点，宽时铺满
  double get reachFactor => 0.72 + width * 0.28;

  /// 每帧推进。[dt] 秒，[w] 当前声像宽度 0..1。
  void tick(double dt, double w) {
    if (dots.isEmpty || dt <= 0) return;
    width = w;

    // 1) 按角度分桶，供邻居查询
    for (final b in _bins) {
      b.clear();
    }
    for (var i = 0; i < dots.length; i++) {
      _bins[_binIndexOf(dots[i])].add(i);
    }

    // 2) 逐个积分
    // 目标壳层：声像宽 → 更外；这个半径只作为弹簧的平衡点，
    // 点不会"瞬移"过去。
    final shell =
        _floor + (1 - _floor) * (_kShellLo + (_kShellHi - _kShellLo) * w);
    for (var i = 0; i < dots.length; i++) {
      final p = dots[i];
      var r = math.sqrt(p.x * p.x + p.y * p.y);
      // r ≈ 0 时没有方向，用上次的角度兜底
      final ux = r > 1e-4 ? p.x / r : math.cos(p.angle);
      final uy = r > 1e-4 ? p.y / r : math.sin(p.angle);

      // ---- 弹簧（朝"自己那层"）+ 重力（朝中心）：甩出去、回落、绕流 ----
      final target = _floor + (shell - _floor) * (0.10 + 0.90 * p.layer);
      final radial = _kSpring * (target - r) - _kGravity;
      var ax = ux * radial * p.temper;
      var ay = uy * radial * p.temper;

      // ---- 切向扰动：绕中心流动，不至于像烟花纯放射 ----
      ax += -uy * _kSwirl * p.temper;
      ay += ux * _kSwirl * p.temper;

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
          ax += (cohX / cnt - p.x) * 0.8;
          ay += (cohY / cnt - p.y) * 0.8;
          ax += (aliX / cnt - p.vx) * 1.7;
          ay += (aliY / cnt - p.vy) * 1.7;
          ax += sepX;
          ay += sepY;
        }
      }

      // ---- 限速 + 阻尼 ----
      p.vx += ax * dt;
      p.vy += ay * dt;
      final damping = 1 - 0.95 * dt;
      p.vx *= damping;
      p.vy *= damping;
      final sp = math.sqrt(p.vx * p.vx + p.vy * p.vy);
      if (sp > _kMaxSpeed) {
        final k = _kMaxSpeed / sp;
        p.vx *= k;
        p.vy *= k;
      }

      p.x += p.vx * dt;
      p.y += p.vy * dt;
      r = math.sqrt(p.x * p.x + p.y * p.y);

      // ---- 内圈地板：落到封面外面就弹起来（保底跳速，永远有动静） ----
      if (r < _floor) {
        final vr = p.vx * ux + p.vy * uy;
        p.x = ux * _floor;
        p.y = uy * _floor;
        r = _floor;
        if (vr < 0) {
          // 反弹：径向分量反向并衰减，再给一点随机扰动
          final rebound = math.max(_kHop, -vr * _kRestFloor);
          p.vx += ux * (rebound - vr);
          p.vy += uy * (rebound - vr);
          p.vx += (_rng.nextDouble() - 0.5) * 0.10;
          p.vy += (_rng.nextDouble() - 0.5) * 0.10;
        }
      } else if (r > 1) {
        // ---- 外墙：别飞出视口 ----
        final vr = p.vx * ux + p.vy * uy;
        p.x = ux;
        p.y = uy;
        r = 1;
        if (vr > 0) {
          final rebound = vr * _kRestWall;
          p.vx += ux * (rebound - vr) * 2;
          p.vy += uy * (rebound - vr) * 2;
        }
      }

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
    // 整体浓度跟宽度走，但给足底：窄声像时也要看得见点
    final base = 0.34 + controller.width * 0.40;

    const ab = ImagerFieldController.alphaBuckets;
    const sb = ImagerFieldController.sizeBuckets;
    final bufs = controller.pointBufs;
    final lens = controller.pointLens;
    for (var i = 0; i < lens.length; i++) {
      lens[i] = 0;
    }

    // 分档：逐点 drawCircle 是几百次独立绘制调用，按 (亮度 × 半径) 分 12 档
    // 批量画就只剩 12 次 drawRawPoints。
    for (final p in dots) {
      final bi = (p.gain * (ab - 1)).round().clamp(0, ab - 1);
      final k = bi * sb + (p.gain > 0.78 ? 1 : 0);
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
