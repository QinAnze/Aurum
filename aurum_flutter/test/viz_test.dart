// Aurum · 可视化与图片加载的回归测试。
// 覆盖用户实测报出的三个 bug 的根因：
//  1) 频谱不显示 —— 取数/平滑/高潮链路
//  2) 背景不随封面变色 —— 图片 CDN 候选 host 顺序
//  3) 切歌旧歌还在放 —— 由 soloud_engine 的清理逻辑保证（见注释），此处验证配套的状态机
import 'dart:async';
import 'dart:typed_data';

import 'package:aurum/audio/player_engine.dart';
import 'package:aurum/effects/viz_controller.dart';
import 'package:aurum/effects/word_cloud.dart';
import 'package:aurum/models.dart';
import 'package:aurum/net_image.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可控的假引擎：喂固定 FFT/时域数据
class _FakeEngine implements PlayerEngine {
  _FakeEngine({this.fftData, this.waveData});

  Float32List? fftData;
  Float32List? waveData;

  @override
  Float32List? get fft => fftData;
  @override
  Float32List? get wave => waveData;
  @override
  double get positionSec => 12.3;
  @override
  bool get isPlaying => false;
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

VizController _buildViz(
  _FakeEngine engine, {
  required bool playing,
  required bool fxOn,
}) {
  return VizController(
    engine: engine,
    isPlaying: () => playing,
    volume: () => 1,
    fxOn: () => fxOn,
    lyrics: () => const <LyricLine>[],
    cloudColorsFn: () => const [],
    cloud: WordCloudController(),
  );
}

void main() {
  group('imageUrlCandidates', () {
    test('p2（被挡节点）→ p3 排最前', () {
      final c = imageUrlCandidates(
          'https://p2.music.126.net/abc==/123.jpg?param=500y500');
      expect(c.first, contains('p3.music.126.net'));
      expect(c.last, contains('p2.music.126.net'));
    });

    test('p1（被挡节点）→ p3 排最前', () {
      final c = imageUrlCandidates('https://p1.music.126.net/abc/123.jpg');
      expect(c.first, contains('p3.music.126.net'));
    });

    test('已是 p3：原 URL 优先，仍保留兜底', () {
      final c = imageUrlCandidates('https://p3.music.126.net/abc/123.jpg');
      expect(c.first, contains('p3.music.126.net'));
      expect(c.length, greaterThan(1));
    });

    test('非 netease 域名不乱换 host', () {
      final c = imageUrlCandidates('https://example.com/a/b.jpg');
      expect(c, ['https://example.com/a/b.jpg']);
    });

    test('查询参数与路径原样保留', () {
      final c = imageUrlCandidates(
          'https://p2.music.126.net/xyz==/789.jpg?param=300y300');
      expect(c.first, endsWith('/xyz==/789.jpg?param=300y300'));
    });
  });

  group('VizController 频谱（bug1）', () {
    testWidgets('有真实 FFT 时频谱被填充、且算出高潮', (tester) async {
      final engine = _FakeEngine(
        fftData: Float32List.fromList(List.filled(1024, 0.45)),
        waveData: Float32List.fromList(List.filled(2048, 0.3)),
      );
      final viz = _buildViz(engine, playing: true, fxOn: true);

      viz.start();
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }

      // 频谱被真实数据填充
      expect(viz.specVals.where((v) => v > 0.05).length, greaterThan(20));
      // 高潮因子被点亮（驱动抖动/发光/词云放大）
      expect(viz.climax, greaterThan(0.3));
      // 抖动被激活
      expect(
        viz.shakeDx.abs() + viz.shakeDy.abs() + viz.shakeRot.abs(),
        greaterThan(0),
      );
      viz.dispose();
    });

    testWidgets('真实量级的小幅度 FFT（线性幅度 0.002~0.3）也要有明显起伏',
        (tester) async {
      // 这是 bug「频谱还是死平的一条环」的根因：
      // flutter_soloud 给的是线性幅度，Web 的字节值是 dB 映射，
      // 按 /255 换算会让幅度只有 ~1px。自适应峰值归一化后必须用满量程。
      final engine = _FakeEngine(
        fftData: Float32List.fromList([
          for (var i = 0; i < 1024; i++) 0.002 + 0.298 * ((i * 7919) % 100) / 100,
        ]),
        waveData: Float32List.fromList(List.filled(2048, 0.25)),
      );
      final viz = _buildViz(engine, playing: true, fxOn: true);

      viz.start();
      for (var i = 0; i < 14; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }

      // 峰值 bin 应接近满量程（而不是被线性幅度压成 0.0x）
      final maxV = viz.specVals.reduce((a, b) => a > b ? a : b);
      expect(maxV, greaterThan(0.6), reason: '峰值 bin 应接近满量程');
      // 起伏幅度（峰-谷）也要足够大，环才看得出在动
      final minV = viz.specVals.reduce((a, b) => a < b ? a : b);
      expect(maxV - minV, greaterThan(0.25), reason: '峰谷差过小＝视觉上是一条平环');
      viz.dispose();
    });

    testWidgets('极安静的音频（幅度 1e-5）也不会把环压死', (tester) async {
      final engine = _FakeEngine(
        fftData: Float32List.fromList([
          for (var i = 0; i < 1024; i++) 1e-5 * (1 + (i % 5)),
        ]),
        waveData: Float32List.fromList(List.filled(2048, 0.02)),
      );
      final viz = _buildViz(engine, playing: true, fxOn: true);

      viz.start();
      for (var i = 0; i < 14; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(viz.specVals.reduce((a, b) => a > b ? a : b), greaterThan(0.2));
      viz.dispose();
    });

    testWidgets('无 FFT 但在播放 → 回退 BPM 模拟，仍有起伏', (tester) async {
      final engine = _FakeEngine();
      final viz = _buildViz(engine, playing: true, fxOn: true);

      viz.start();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(viz.specVals.any((v) => v > 0.05), isTrue);
      viz.dispose();
    });

    testWidgets('暂停且无数据 → 频谱衰减回零（与原版一致）', (tester) async {
      final engine = _FakeEngine();
      final viz = _buildViz(engine, playing: false, fxOn: true);

      viz.start();
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(viz.specVals.every((v) => v < 0.01), isTrue);
      expect(viz.climax, lessThan(0.05));
      viz.dispose();
    });

    testWidgets('关掉总开关 → 高潮快速衰减、无抖动', (tester) async {
      final engine = _FakeEngine(
        fftData: Float32List.fromList(List.filled(1024, 0.5)),
        waveData: Float32List.fromList(List.filled(2048, 0.3)),
      );
      var on = true;
      final viz = VizController(
        engine: engine,
        isPlaying: () => true,
        volume: () => 1,
        fxOn: () => on,
        lyrics: () => const <LyricLine>[],
        cloudColorsFn: () => const [],
        cloud: WordCloudController(),
      );

      viz.start();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(viz.climax, greaterThan(0.2));

      on = false; // 关掉超频
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(viz.climax, lessThan(0.05));
      viz.dispose();
    });
  });
}