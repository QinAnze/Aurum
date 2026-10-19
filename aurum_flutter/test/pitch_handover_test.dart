// 相位交接：歌词段 → 无歌词段（含超长句唱过 8s）时，
// 中心音高与背景词云先落下去，平铺音高延后出场，三者不并存。
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:aurum/audio/player_engine.dart';
import 'package:aurum/effects/pitch_detector.dart';
import 'package:aurum/effects/viz_controller.dart';
import 'package:aurum/effects/word_cloud.dart';
import 'package:aurum/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 位置可变、波形是 440Hz 正弦的假引擎
class _Engine implements PlayerEngine {
  double pos = 0;
  late final Float32List _wave = Float32List.fromList([
    for (var i = 0; i < 2048; i++)
      0.25 * math.sin(2 * math.pi * 440 * i / 44100),
  ]);

  @override
  double get positionSec => pos;
  @override
  Float32List? get fft => null;
  @override
  Float32List? get wave => _wave;
  @override
  bool get isPlaying => true;
  @override
  bool get hasSource => true;
  @override
  double get durationSec => 200;
  @override
  double get volume => 1;
  @override
  Stream<EngineEvent> get events => const Stream.empty();
  @override
  Future<void> init() async {}
  @override
  Future<bool> loadAndPlay(List<String> urls) async => true;
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(double sec) async {}
  @override
  Future<void> setVolume(double v) async {}
  @override
  void dispose() {}
}

VizController _build(_Engine e) => VizController(
      engine: e,
      isPlaying: () => true,
      volume: () => 1,
      fxOn: () => true,
      lyrics: () => [
        LyricLine(t: 0, text: 'a very long line'),
        LyricLine(t: 20, text: 'next'),
      ],
      cloudColorsFn: () => const [],
      cloud: WordCloudController(),
    );

void main() {
  testWidgets('8s 一到：中心音高让位，平铺延后，两者不同框', (tester) async {
    final e = _Engine()..pos = 7.0;
    final viz = _build(e);
    // 测试里没有 UI 树，画布尺寸要手动喂（真实运行时由词云层的 LayoutBuilder 回填）
    viz.setCanvasSize(const Size(1280, 800));
    viz.start();

    // 先在歌词段跑几帧：中央字母这一侧应当有值（或至少相位是 vocal）
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(viz.window.phase, PitchPhase.vocal);
    expect(viz.scatter.words, isEmpty);

    // 越过 8s → 切到无歌词段
    e.pos = 8.1;
    await tester.pump(const Duration(milliseconds: 16));
    expect(viz.window.phase, PitchPhase.instrument);
    expect(viz.pitchNote, isNull, reason: '中心音高立刻让位，不该还挂着');
    expect(viz.scatter.words, isEmpty, reason: '交接期还没开始铺');

    // 交接期内（<0.5s）：仍然不能有平铺字
    for (var i = 0; i < 18; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(viz.scatter.words, isEmpty,
        reason: '中央字母/词云还在落，平铺不能插进来');

    // 交接期过后：开始铺
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(viz.scatter.words, isNotEmpty, reason: '交接完成后应开始铺散落');

    viz.dispose();
  });

  testWidgets('高潮时音高字与歌名同步发光放大', (tester) async {
    final e = _Engine()..pos = 0.2;
    final viz = _build(e);
    viz.setCanvasSize(const Size(1280, 800));
    viz.start();
    // 响度足够时 climax 会爬上去（song title 用的是同一条曲线）
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(viz.climax, greaterThan(0.1), reason: '需要先进入高潮段');
    expect(viz.pitchScale, greaterThan(1.0), reason: '高潮时音高字要放大');
    expect(viz.pitchGlow, greaterThan(0.05), reason: '高潮时音高字要发光');
    // 平铺控制器也拿到了同一份脉动
    expect(viz.scatter.pulse, closeTo(viz.pitchScale, 0.02));
    expect(viz.scatter.glow, greaterThan(0.0));
    viz.dispose();
  });

  testWidgets('切到无歌词段时，背景词云立刻转成坠落', (tester) async {
    final e = _Engine()..pos = 0.2;
    final viz = _build(e);
    viz.setCanvasSize(const Size(1280, 800));
    viz.start();
    // 让词云把当前这句的词吐出来
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final before = viz.cloud.words.length;

    e.pos = 8.1;
    await tester.pump(const Duration(milliseconds: 16));

    // 词云里的词应当全部进入坠落（或已经落完）
    final stillUp = viz.cloud.words.where((w) => w.phase != 'fall').length;
    expect(stillUp, 0,
        reason: '切走时词云要整句落下（before=$before）');
    viz.dispose();
  });
}
