// 音高检测回归：音名换算 / 响度门槛 / 高频排除 / 取窗口内最高音 / 长间隙定位。
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:aurum/effects/pitch_detector.dart';
import 'package:aurum/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 构造一帧正弦波形（幅度 [amp]，频率 [hz]）
Float32List _sine(double hz, {double amp = 0.25, int n = 2048}) {
  final w = Float32List(n);
  for (var i = 0; i < n; i++) {
    w[i] = amp * math.sin(2 * math.pi * hz * i / 44100);
  }
  return w;
}

/// 喂 [frames] 帧，返回是否锁定了音
bool _feed(PitchDetector d, double hz, {double amp = 0.25, int frames = 5}) {
  var locked = false;
  for (var i = 0; i < frames; i++) {
    locked = d.update(_sine(hz, amp: amp)) || locked;
  }
  return locked;
}

void main() {
  test('音名换算：440→A4，659.25→E5，261.63→C4', () {
    final d = PitchDetector();
    expect(_feed(d, 440), isTrue);
    expect(d.note, 'A4');

    final d2 = PitchDetector();
    expect(_feed(d2, 659.25), isTrue);
    expect(d2.note, 'E5');

    final d3 = PitchDetector();
    expect(_feed(d3, 261.63), isTrue);
    expect(d3.note, 'C4');
  });

  test('同一窗口内取最高音：先 G4 后 G5，字母变成 G5', () {
    final d = PitchDetector();
    expect(_feed(d, 392.0), isTrue);
    expect(d.note, 'G4');

    expect(_feed(d, 784.0), isTrue);
    expect(d.note, 'G5', reason: '更高的音应当覆盖低音');
  });

  test('响度不足的杂音不锁定（RMS 门槛）', () {
    final d = PitchDetector();
    final locked = _feed(d, 1200, amp: 0.005, frames: 10);
    expect(locked, isFalse);
    expect(d.note, isNull);
  });

  test('镲片/齿音那种高频噪声不锁定', () {
    // 纯 8kHz 正弦会被自相关锁到它的次谐波（≈4kHz），真实音乐里
    // 这种「纯高频单音」不存在；镲片/齿音是宽带噪声，靠置信度挡。
    final d = PitchDetector();
    var seed = 12345;
    final w = Float32List(2048);
    var locked = false;
    for (var f = 0; f < 10; f++) {
      for (var i = 0; i < w.length; i++) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        w[i] = ((seed / 0x7fffffff) * 2 - 1) * 0.3;
      }
      locked = d.update(w) || locked;
    }
    expect(locked, isFalse);
    expect(d.note, isNull);
  });

  test('低于下限的贝斯（80Hz）不算 lead', () {
    final d = PitchDetector();
    final locked = _feed(d, 80, amp: 0.3, frames: 10);
    expect(locked, isFalse);
    expect(d.note, isNull);
  });

  test('长间隙定位：两句 >10s 才开窗，窗口按前一句起点界定', () {
    final lines = [
      LyricLine(t: 0, text: 'a'),
      LyricLine(t: 5, text: 'b'), // 0→5 只有 5s
      LyricLine(t: 20, text: 'c'), // 5→20 = 15s ✓
      LyricLine(t: 25, text: 'd'), // 20→25 只有 5s
    ];
    expect(longGapAt(lines, 2), isNull);
    final gap = longGapAt(lines, 10);
    expect(gap, isNotNull);
    expect(gap!.start, 5);
    expect(gap.end, 20);
    expect(gap.index, 1);
    expect(longGapAt(lines, 22), isNull);
    // 边界：窗口末尾（下一句开始）就该关窗
    expect(longGapAt(lines, 20), isNull);
  });

  test('阈值是 8s：整 8s 不算，8.5s 算', () {
    final a = [LyricLine(t: 0, text: 'a'), LyricLine(t: 8, text: 'b')];
    expect(longGapAt(a, 4), isNull);
    final b = [LyricLine(t: 0, text: 'a'), LyricLine(t: 8.5, text: 'b')];
    expect(longGapAt(b, 4), isNotNull);
  });

  test('reset 后清空已锁定的音', () {
    final d = PitchDetector();
    _feed(d, 440);
    expect(d.note, 'A4');
    d.reset();
    expect(d.note, isNull);
    expect(d.revision, 0);
  });
}
