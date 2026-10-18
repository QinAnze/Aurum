// Kick 检测回归：中低频快速冲击 → 打光包络；持续低频/纯高频/关特效都不该触发。
//
// 注意数据源是**时域波形**（线性幅度）。flutter_soloud 的 fft 是 dB 归一化到
// 0..1，贝斯段长期饱和在 1.0，动态范围不足以判断冲击（这正是第一版失效的原因）。
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:aurum/effects/kick_detector.dart';
import 'package:flutter_test/flutter_test.dart';

const double _dt = 1 / 60;
const int _n = 2048;

/// 构造一帧正弦波形
Float32List _wave({double amp = 0, double hz = 60}) {
  final w = Float32List(_n);
  for (var i = 0; i < _n; i++) {
    w[i] = amp * math.sin(2 * math.pi * hz * i / 44100);
  }
  return w;
}

void _warmUp(KickDetector k, {double amp = 0.02, int frames = 40}) {
  for (var i = 0; i < frames; i++) {
    k.update(_wave(amp: amp), _dt);
  }
}

void main() {
  test('低频冲击被判为 kick，包络瞬间到 1', () {
    final k = KickDetector();
    _warmUp(k);

    // 分几帧爬升（46ms 的分析窗本身会把起音铺开）
    var hit = false;
    for (final amp in [0.05, 0.15, 0.35]) {
      final h = k.update(_wave(amp: amp), _dt);
      if (h) {
        expect(k.env, 1.0, reason: '命中那一帧包络必须是满的');
        hit = true;
      }
    }
    expect(hit, isTrue, reason: '60Hz 的快速冲击应当触发');
  });

  test('不应期内不重复触发（一次鼓点只亮一次）', () {
    final k = KickDetector();
    _warmUp(k);
    expect(k.update(_wave(amp: 0.35), _dt), isTrue);

    for (var i = 0; i < 3; i++) {
      expect(k.update(_wave(amp: 0.4), _dt), isFalse);
    }
  });

  test('只有高频的冲击不算 kick（低通把它们滤掉）', () {
    final k = KickDetector();
    _warmUp(k);
    expect(k.update(_wave(amp: 0.5, hz: 4000), _dt), isFalse);
  });

  test('持续低频（贝斯长音）最多因起音多闪一两次，不会一直闪', () {
    final k = KickDetector();
    _warmUp(k);
    k.update(_wave(amp: 0.3), _dt); // 起音

    var hits = 0;
    for (var i = 0; i < 120; i++) {
      if (k.update(_wave(amp: 0.3), _dt)) hits++;
    }
    expect(hits, lessThanOrEqualTo(2), reason: '稳态低频不应反复打光');
  });

  test('特效关闭时不再触发，包络指数回落', () {
    final k = KickDetector();
    _warmUp(k);
    expect(k.update(_wave(amp: 0.35), _dt), isTrue);
    final peak = k.env;

    for (var i = 0; i < 30; i++) {
      expect(k.update(null, _dt, active: false), isFalse);
    }
    expect(k.env, lessThan(peak * 0.1), reason: '关掉后 0.5s 内应基本熄灭');
  });

  test('低通滤波器：60Hz 基本原样，4kHz 被压掉两个数量级', () {
    final k = KickDetector();
    final low60 = k.lowRms(_wave(amp: 0.5, hz: 60));
    final high4k = k.lowRms(_wave(amp: 0.5, hz: 4000));
    expect(low60, greaterThan(0.25));
    expect(high4k, lessThan(low60 * 0.02));
  });
}
