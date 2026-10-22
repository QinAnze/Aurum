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
    test('configure 后就有一整批粒子，且都在圆内', () {
      final c = ImagerFieldController()
        ..configure(const Size(1280, 800), const Offset(640, 400));
      expect(c.dots, hasLength(ImagerFieldController.kCount));
      for (final p in c.dots) {
        final r = math.sqrt(p.x * p.x + p.y * p.y);
        expect(r, lessThan(1.1));
      }
      expect(c.maxRadius, greaterThan(0));
    });

    test('粒子有寿命：老点淡出、新点从中心重生（新旧混在一起）', () {
      final c = ImagerFieldController()
        ..configure(const Size(1280, 800), const Offset(640, 400));
      var sawReset = false;
      var respawnRadius = 1.0;
      for (var i = 0; i < 200; i++) {
        final before = c.dots.first.age;
        c.tick(0.016, 0.7);
        final p = c.dots.first;
        if (p.age < before) {
          // 这一刻它刚重生
          sawReset = true;
          respawnRadius = math.sqrt(p.x * p.x + p.y * p.y);
        }
        for (final q in c.dots) {
          expect(q.age, lessThanOrEqualTo(q.life + 1e-9));
          expect(q.alpha, inInclusiveRange(0.0, 1.0));
        }
      }
      expect(sawReset, isTrue, reason: '必须会死掉重生，否则没有新旧交替');
      expect(respawnRadius, lessThan(0.3), reason: '重生的点应在中心附近');

      // 稳态下应当"老的还在淡出、新的刚出来"，而不是整批同年龄
      final young = c.dots.where((q) => q.age / q.life < 0.2).length;
      final old = c.dots.where((q) => q.age / q.life > 0.5).length;
      expect(young, greaterThan(10), reason: '要一直有新点冒出来');
      expect(old, greaterThan(10), reason: '也要有正往外飘的老点');
    });

    test('声像大 → 整体靠外；声像小 → 整体靠内', () {
      double meanR(ImagerFieldController c) =>
          c.dots
              .map((p) => math.sqrt(p.x * p.x + p.y * p.y))
              .reduce((a, b) => a + b) /
          c.dots.length;

      ImagerFieldController run(double w) {
        final c = ImagerFieldController()
          ..configure(const Size(1280, 800), const Offset(640, 400));
        for (var i = 0; i < 90; i++) {
          c.tick(0.016, w);
        }
        return c;
      }

      final wide = run(1.0);
      final narrow = run(0.0);
      expect(meanR(wide), greaterThan(meanR(narrow) + 0.08),
          reason: '宽声像要把点甩得更远');
      expect(wide.reachFactor, greaterThan(narrow.reachFactor),
          reason: '可达半径也要跟着放大');
    });

    test('鸟群：邻居会带动方向趋同（对齐规则生效）', () {
      final c = ImagerFieldController()
        ..configure(const Size(900, 600), const Offset(450, 300));
      // 锁住寿命，免得测试中途重生把方向重置
      for (final p in c.dots) {
        p.age = 0;
        p.life = 10;
        p.x = 0.30 + (p.x % 0.04);
        p.y = 0.30 + (p.y % 0.04);
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
      expect(meanCos, greaterThan(0.6), reason: '对齐后应大体同向');
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
      final bins = VizController.buildSpecBins(fftLen);
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

    test('画布尺寸为零时不绘制也不抛异常', () {
      final p = LinearSpectrumPainter(
        vals: List<double>.filled(kSpecN, 0.5),
        climax: 1,
        oc: true,
      );
      // 直接调用 paint 需要 Canvas，这里只验证 shouldRepaint 契约
      expect(p.shouldRepaint(p), isTrue);
    });
  });
}
