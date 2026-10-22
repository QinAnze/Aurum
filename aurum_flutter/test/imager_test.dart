// 声像检测 / 颗粒场 / 直线频谱的回归。
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:aurum/effects/imager_detector.dart';
import 'package:aurum/effects/imager_field.dart';
import 'package:aurum/effects/linear_spectrum.dart';
import 'package:aurum/effects/spectrum_ring.dart';
import 'package:aurum/effects/viz_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造一段左右声道：mid 成分幅度 a，side 成分幅度 b
/// （L = a + b，R = a - b，于是 mid = a、side = b）
(Float32List, Float32List) _stereo({
  required double mid,
  required double side,
  int n = 2048,
}) {
  final l = Float32List(n);
  final r = Float32List(n);
  for (var i = 0; i < n; i++) {
    final s = math.sin(2 * math.pi * 220 * i / 44100);
    l[i] = (mid + side) * s;
    r[i] = (mid - side) * s;
  }
  return (l, r);
}

void main() {
  group('ImagerDetector', () {
    test('完全单声道（L == R）→ 宽度 0', () {
      final d = ImagerDetector();
      final (l, r) = _stereo(mid: 0.3, side: 0);
      for (var i = 0; i < 12; i++) {
        d.update(l, r, active: true);
      }
      expect(d.width, lessThan(0.02), reason: '左右一样就没有宽度');
    });

    test('纯反相（L == -R）→ 宽度打满', () {
      final d = ImagerDetector();
      final (l, r) = _stereo(mid: 0, side: 0.3);
      for (var i = 0; i < 20; i++) {
        d.update(l, r, active: true);
      }
      expect(d.width, greaterThan(0.9), reason: '完全反相是最宽');
    });

    test('灵敏度：side/mid = 0.25 就应到 0.5 左右', () {
      final d = ImagerDetector();
      // side/(mid+side) = 0.25/(1+0.25) = 0.2 → 归一化 0.2/0.5 = 0.4
      final (l, r) = _stereo(mid: 1.0, side: 0.25);
      for (var i = 0; i < 30; i++) {
        d.update(l, r, active: true);
      }
      expect(d.width, closeTo(0.4, 0.05), reason: '不能等到真反相才动');
    });

    test('起快落慢：张开跟得上，收得慢', () {
      final d = ImagerDetector();
      final (wideL, wideR) = _stereo(mid: 1.0, side: 0.8);
      d.update(wideL, wideR, active: true);
      final afterOne = d.width;
      expect(afterOne, greaterThan(0.4), reason: '一帧就要跟上大半');

      final (monoL, monoR) = _stereo(mid: 1.0, side: 0);
      d.update(monoL, monoR, active: true);
      expect(d.width, greaterThan(afterOne * 0.8), reason: '回落要慢');
    });

    test('静音 / 无分声道 / 不活跃 → 衰减到 0', () {
      final d = ImagerDetector();
      final (l, r) = _stereo(mid: 0.5, side: 0.5);
      for (var i = 0; i < 10; i++) {
        d.update(l, r, active: true);
      }
      expect(d.width, greaterThan(0.3));
      for (var i = 0; i < 120; i++) {
        d.update(null, null, active: false);
      }
      expect(d.width, lessThan(0.02));
    });

    test('reset 归零', () {
      final d = ImagerDetector()..width = 0.8;
      d.reset();
      expect(d.width, 0);
    });
  });

  group('ImagerFieldController', () {
    double meanR(ImagerFieldController c) =>
        c.dots
            .map((p) => math.sqrt(p.x * p.x + p.y * p.y))
            .reduce((a, b) => a + b) /
        c.dots.length;

    test('configure 后铺满粒子，全部落在地板与外圈之间', () {
      final c = ImagerFieldController()
        ..configure(const Size(1280, 800), const Offset(640, 400));
      expect(c.dots, hasLength(ImagerFieldController.kCount));
      for (final p in c.dots) {
        final r = math.sqrt(p.x * p.x + p.y * p.y);
        expect(r, greaterThanOrEqualTo(c.floorRadius - 1e-9));
        expect(r, lessThanOrEqualTo(1.001));
      }
      expect(c.maxRadius, greaterThan(0));
    });

    test('内圈地板在封面圆内侧（封面半透明，点能透出来）', () {
      final c = ImagerFieldController()
        ..configure(const Size(1280, 800), const Offset(640, 400),
            coverRadius: 150);
      // maxR = 800 * 0.62 = 496；150/496*0.62 ≈ 0.187
      final coverRel = 150 / c.maxRadius;
      expect(c.floorRadius, lessThan(coverRel));
      expect(c.floorRadius, closeTo(coverRel * 0.62, 0.01));
      expect(c.floorRadius, greaterThan(0.04));
    });

    test('甩出去会自己落回来：先冲高，再被重力拉回内圈', () {
      final c = ImagerFieldController()
        ..configure(const Size(1280, 800), const Offset(640, 400));
      for (final p in c.dots) {
        final r = math.sqrt(p.x * p.x + p.y * p.y);
        final ux = p.x / r, uy = p.y / r;
        // 统一放到外圈附近，并给一个**向外**的速度
        p.x = ux * 0.72;
        p.y = uy * 0.72;
        p.vx = ux * 0.55;
        p.vy = uy * 0.55;
      }
      var peak = 0.0;
      for (var i = 0; i < 150; i++) {
        c.tick(0.016, 0.0); // 声像 0 = 不再外推，只剩重力
        peak = math.max(peak, meanR(c));
      }
      expect(peak, greaterThan(0.72), reason: '初速朝外，应当先冲高');
      expect(meanR(c), lessThan(0.72), reason: '重力要把它们拉回内圈');
    });

    test('声像大 → 整体靠外；声像小 → 整体靠内', () {
      ImagerFieldController run(double w) {
        final c = ImagerFieldController()
          ..configure(const Size(1280, 800), const Offset(640, 400));
        for (var i = 0; i < 120; i++) {
          c.tick(0.016, w);
        }
        return c;
      }

      final wide = run(1.0);
      final narrow = run(0.0);
      expect(meanR(wide), greaterThan(meanR(narrow) + 0.10),
          reason: '宽声像要把点甩得更远');
      // 窄的时候全部挤在地板附近，一个都不许跑出去
      for (final p in narrow.dots) {
        final r = math.sqrt(p.x * p.x + p.y * p.y);
        expect(r, greaterThanOrEqualTo(narrow.floorRadius - 1e-9));
      }
    });

    test('长期跑动不会飞出视口（有墙），数量恒定', () {
      final c = ImagerFieldController()
        ..configure(const Size(900, 600), const Offset(450, 300));
      for (var i = 0; i < 400; i++) {
        c.tick(0.033, 1.0);
      }
      expect(c.dots, hasLength(ImagerFieldController.kCount));
      for (final p in c.dots) {
        final r = math.sqrt(p.x * p.x + p.y * p.y);
        expect(r, lessThan(1.001));
        expect(r, greaterThanOrEqualTo(c.floorRadius - 1e-9));
      }
    });

    test('鸟群：邻居会带动方向趋同（对齐规则生效）', () {
      final c = ImagerFieldController()
        ..configure(const Size(900, 600), const Offset(450, 300));
      for (final p in c.dots) {
        p.x = 0.60 + (p.x % 0.04);
        p.y = 0.60 + (p.y % 0.04);
        p.vx = 0.6;
        p.vy = 0.0;
      }
      for (var i = 0; i < 15; i++) {
        c.tick(0.016, 0.5);
      }
      final dirs = c.dots
          .where((p) {
            final s = math.sqrt(p.vx * p.vx + p.vy * p.vy);
            return s > 0.02;
          })
          .map((p) => math.atan2(p.vy, p.vx))
          .toList();
      expect(dirs, isNotEmpty);
      final meanCos =
          dirs.map((a) => math.cos(a)).reduce((a, b) => a + b) / dirs.length;
      expect(meanCos, greaterThan(0.5), reason: '对齐后应大体同向');
    });

    test('视野为空时不初始化（避免除以零）', () {
      final c = ImagerFieldController()..configure(Size.zero, null);
      expect(c.dots, isEmpty);
      c.tick(0.016, 1);
      expect(c.dots, isEmpty);
    });
  });

  group('频谱频段划分', () {
    test('10Hz 起、21kHz 收，低频分得粗、高频分得细', () {
      const fftLen = 1024;
      final bins = VizController.buildLineBins(fftLen);
      expect(bins, hasLength(kSpecN));
      expect(bins.first, 0, reason: '10Hz 落在 bin 0');
      const binHz = 22050 / fftLen; // 21.5Hz/bin
      expect(bins.last, closeTo(21000 / binHz, 2),
          reason: '21kHz 要落在对应 bin 上');
      for (var i = 1; i < bins.length; i++) {
        expect(bins[i], greaterThanOrEqualTo(bins[i - 1]), reason: '必须单调');
      }

      final lowPts = bins.where((b) => b <= (200 / binHz).round()).length;
      final highPts = bins.where((b) => b >= (2000 / binHz).round()).length;
      expect(lowPts, lessThan(highPts * 0.6),
          reason: '低频占的点数要明显少于高频（低频粗、高频细）');
    });

    test('直线电平：固定 dB 窗口，不跟着"全频段最大值"走', () {
      // raw 是 soloud 给的 0..1（W3C：-100dB→0，-30dB→1）
      expect(VizController.lineLevel(0.46), closeTo(0.0, 0.001));
      expect(VizController.lineLevel(1.0), closeTo(1.0, 0.001));
      expect(VizController.lineLevel(0.20), 0.0, reason: '窗口以下一律 0');

      // 窗口内单调递增，且中段有足够展开（0.73 ≈ -46dB → 约 0.57）
      final mid = VizController.lineLevel(0.73);
      expect(mid, greaterThan(0.4));
      expect(mid, lessThan(0.75));

      var prev = -1.0;
      for (final raw in [0.0, 0.30, 0.46, 0.60, 0.80, 0.95, 1.0]) {
        final v = VizController.lineLevel(raw);
        expect(v, greaterThanOrEqualTo(prev));
        prev = v;
      }

      // 关键：0.9 这种很响的 bin 也不会被抬到 1.0 —— 没有峰值归一化
      expect(VizController.lineLevel(0.90), lessThan(0.95));
    });
  });

  group('LinearSpectrum', () {
    testWidgets('空数据不崩，有数据能画出来', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SizedBox(
          width: 300,
          height: 60,
          child: CustomPaint(
            painter: LinearSpectrumPainter(vals: const [], climax: 0, oc: true),
          ),
        ),
      ));
      expect(tester.takeException(), isNull);

      final vals = List<double>.generate(kSpecN, (i) => i / kSpecN);
      await tester.pumpWidget(MaterialApp(
        home: SizedBox(
          width: 300,
          height: 60,
          child: CustomPaint(
            painter: LinearSpectrumPainter(vals: vals, climax: 0.8, oc: true),
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
    });

    test('shouldRepaint 恒为 true（逐帧数据都在变）', () {
      final p = LinearSpectrumPainter(
        vals: List<double>.filled(kSpecN, 0.5),
        climax: 1,
        oc: true,
      );
      expect(p.shouldRepaint(p), isTrue);
    });
  });
}
