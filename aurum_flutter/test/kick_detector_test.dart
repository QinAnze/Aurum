// Kick 检测回归：中低频快速冲击 → 打光包络；持续低频/纯高频/关特效都不该触发。
import 'dart:typed_data';

import 'package:aurum/effects/kick_detector.dart';
import 'package:flutter_test/flutter_test.dart';

const double _dt = 1 / 60;

/// 构造一帧线性幅度谱：低频段（bin1..6）填 low，中高频段填 high
Float32List _frame({double low = 0, double high = 0}) {
  final f = Float32List(1024);
  for (var i = 1; i <= 6; i++) {
    f[i] = low;
  }
  for (var i = 10; i < 80; i++) {
    f[i] = high;
  }
  return f;
}

/// 预热：喂 n 帧稳态底噪
void _warmUp(KickDetector k, {double low = 0.01, int n = 40}) {
  for (var i = 0; i < n; i++) {
    k.update(_frame(low: low, high: 0.02), _dt);
  }
}

void main() {
  test('低频冲击被判为 kick，包络瞬间到 1', () {
    final k = KickDetector();
    _warmUp(k);

    // 分几帧爬升（引擎的频谱是平滑过的，不是一步到顶）
    var hit = false;
    for (final v in [0.06, 0.14, 0.26]) {
      final h = k.update(_frame(low: v, high: 0.05), _dt);
      if (h) {
        expect(k.env, 1.0, reason: '命中那一帧包络必须是满的');
        hit = true;
      }
    }
    expect(hit, isTrue, reason: '20–150Hz 的快速冲击应当触发');
  });

  test('不应期内不重复触发（一次鼓点只亮一次）', () {
    final k = KickDetector();
    _warmUp(k);
    expect(k.update(_frame(low: 0.26, high: 0.05), _dt), isTrue);

    // 紧随其后的 3 帧（~50ms < 110ms 不应期）
    for (var i = 0; i < 3; i++) {
      expect(k.update(_frame(low: 0.30, high: 0.05), _dt), isFalse);
    }
  });

  test('只有高频的冲击不算 kick', () {
    final k = KickDetector();
    _warmUp(k);
    expect(k.update(_frame(low: 0.01, high: 0.5), _dt), isFalse);
  });

  test('持续低频（贝斯长音）最多因平滑尾巴多闪一两次，不会一直闪', () {
    final k = KickDetector();
    _warmUp(k);
    k.update(_frame(low: 0.2, high: 0.05), _dt); // 起音

    var hits = 0;
    for (var i = 0; i < 120; i++) {
      if (k.update(_frame(low: 0.2, high: 0.05), _dt)) hits++;
    }
    expect(hits, lessThanOrEqualTo(2), reason: '稳态低频不应反复打光');
  });

  test('特效关闭时不再触发，包络指数回落', () {
    final k = KickDetector();
    _warmUp(k);
    expect(k.update(_frame(low: 0.26, high: 0.05), _dt), isTrue);
    final peak = k.env;

    for (var i = 0; i < 30; i++) {
      expect(k.update(null, _dt, active: false), isFalse);
    }
    expect(k.env, lessThan(peak * 0.1), reason: '关掉后 0.5s 内应基本熄灭');
  });
}
