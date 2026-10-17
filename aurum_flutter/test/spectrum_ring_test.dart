// 频谱环的回归测试：锁死「画布被压缩 → 整条环消失」这个坑。
//
// 背景：CoverArt 把环放进 Stack（默认 StackFit.loose），Stack 会把非 positioned
// 子件压到自身尺寸（= 封面边长），导致 160% 的环画布只剩 100%，
// baseR 反超画布半径 → ampMax 为负 → painter 直接 return → 频谱「完全不存在」。

import 'dart:typed_data';

import 'package:aurum/audio/player_engine.dart';
import 'package:aurum/effects/spectrum_ring.dart';
import 'package:aurum/effects/viz_controller.dart';
import 'package:aurum/effects/word_cloud.dart';
import 'package:aurum/widgets/cover.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const double kCover = 300;

void main() {
  group('ringAmpMax', () {
    test('正常画布（封面 160%）→ 振幅接近画布边缘', () {
      final half = kCover * 1.6 / 2; // 240
      final amp = ringAmpMax(half, kCover);
      // 240*0.92 - 300/2*1.02 = 220.8 - 153 = 67.8
      expect(amp, closeTo(67.8, 0.5));
    });

    test('画布被 Stack(loose) 压成 100% → 振幅仍为正（环不能消失）', () {
      final half = kCover / 2; // 150（被压后的画布半径）
      final amp = ringAmpMax(half, kCover);
      // 旧实现：150*0.92 - 153 = -15 → return → 一条线都不画
      expect(amp, greaterThan(0), reason: '画布被压缩时环也必须画出来');
      expect(amp, closeTo(150 * 0.12, 0.5)); // 走兜底下限
    });

    test('极端压缩（画布仅封面 40%）→ 依然为正', () {
      final amp = ringAmpMax(kCover * 0.4 / 2, kCover);
      expect(amp, greaterThan(0));
    });

    test('单调性：画布越大振幅越大（达到设计尺寸后）', () {
      final a = ringAmpMax(kCover * 1.4 / 2, kCover);
      final b = ringAmpMax(kCover * 1.8 / 2, kCover);
      expect(b, greaterThan(a));
    });
  });

  group('Stack(loose) 中的环画布尺寸', () {
    testWidgets('OverflowBox 让 160% 画布拿回真实尺寸（不被 Stack 压扁）',
        (tester) async {
      const coverSize = 300.0;
      const ringSize = coverSize * 1.6; // 480
      final key = GlobalKey();

      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: coverSize,
            height: coverSize,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                OverflowBox(
                  alignment: Alignment.center,
                  maxWidth: ringSize,
                  maxHeight: ringSize,
                  child: SizedBox(
                    key: key,
                    width: ringSize,
                    height: ringSize,
                    child: const CustomPaint(painter: _NoopPainter()),
                  ),
                ),
              ],
            ),
          ),
        ),
      ));

      final box = key.currentContext!.findRenderObject() as RenderBox;
      expect(box.size.width, closeTo(ringSize, 0.5));
      expect(box.size.height, closeTo(ringSize, 0.5));
    });

    testWidgets('对照：不用 OverflowBox 时画布会被 Stack 压成封面大小',
        (tester) async {
      const coverSize = 300.0;
      const ringSize = coverSize * 1.6;
      final key = GlobalKey();

      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: coverSize,
            height: coverSize,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                SizedBox(
                  key: key,
                  width: ringSize,
                  height: ringSize,
                  child: const CustomPaint(painter: _NoopPainter()),
                ),
              ],
            ),
          ),
        ),
      ));

      final box = key.currentContext!.findRenderObject() as RenderBox;
      // 这正是 bug 成因：期望 480，实际被压成 300
      expect(box.size.width, closeTo(coverSize, 0.5));
    });
  });

  _ringWidgetTests();
}

class _NoopPainter extends CustomPainter {
  const _NoopPainter();

  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool shouldRepaint(_NoopPainter old) => false;
}

/// 直接对真实 CoverArt 断言：环画布必须是封面的 1.6 倍（而不是被 Stack 压成 1 倍）。
/// 这是「频谱完全不存在」这条 bug 的最终防线。
class _RingStubEngine implements PlayerEngine {
  @override
  Future<void> init() async {}

  @override
  Future<bool> loadAndPlay(List<String> urls) async => false;

  @override
  bool get hasSource => false;

  @override
  bool get isPlaying => false;

  @override
  double get positionSec => 0;

  @override
  double get durationSec => 0;

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(double sec) async {}

  @override
  double get volume => 1;

  @override
  Future<void> setVolume(double v) async {}

  @override
  Stream<EngineEvent> get events => const Stream.empty();

  @override
  Float32List? get fft => null;

  @override
  Float32List? get wave => null;

  @override
  void dispose() {}
}

void _ringWidgetTests() {
  testWidgets('CoverArt 中环画布 = 封面 1.6 倍', (tester) async {
    const coverSize = 300.0;
    final viz = VizController(
      engine: _RingStubEngine(),
      isPlaying: () => false,
      volume: () => 1,
      fxOn: () => true,
      lyrics: () => const [],
      cloudColorsFn: () => const [Color(0xFFFFFFFF)],
      cloud: WordCloudController(),
    );
    addTearDown(viz.dispose);

    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: CoverArt(
          url: null,
          spinning: false,
          viz: viz,
          c1: const Color(0xFF888888),
          size: coverSize,
        ),
      ),
    ));

    final paints = find.byType(CustomPaint).evaluate().toList();
    expect(paints, isNotEmpty, reason: '环应作为 CustomPaint 上屏');
    final box = paints.first.findRenderObject() as RenderBox;
    expect(box.size.width, closeTo(coverSize * 1.6, 1.0),
        reason: '环画布被压缩会导致 ampMax 转负、整圈不画');
    expect(box.size.height, closeTo(coverSize * 1.6, 1.0));
  });
}
