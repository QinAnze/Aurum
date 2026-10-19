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

  test('频率精度：误差 <1%，不出现半个半音的偏移', () {
    // 抛物线插值的分母符号曾经写反，导致系统性偏 0.5–3%：
    // 659.25Hz（E5）被算成 639Hz，音名掉到 D#5。这条守住插值方向。
    for (final hz in [
      220.0, 329.63, 392.0, 440.0, 523.25, 659.25, 880.0, 1046.5,
    ]) {
      final d = PitchDetector();
      d.update(_sine(hz));
      final err = (d.lastHz - hz).abs() / hz;
      expect(err, lessThan(0.01), reason: '$hz Hz 测得 ${d.lastHz}，误差 $err');
      final midi = (69 + 12 * (math.log(hz / 440) / math.ln2)).round();
      expect(d.note, midiNoteName(midi),
          reason: '$hz Hz 的音名应为 ${midiNoteName(midi)}');
    }
  });

  test('minLag 跟着 maxHz 走：人声档不会把 5kHz 当基频', () {
    // 人声档 maxHz=1100 → minLag 应为 fs/1100 ≈ 20，而不是被错误地夹到 4
    final d = PitchDetector.vocal();
    for (var f = 0; f < 6; f++) {
      d.update(_sine(3000, amp: 0.3));
    }
    // 3kHz 在人声上限之外，即使被测到也会被 hz > maxHz 丢掉
    if (d.lastValid) {
      expect(d.lastHz, lessThanOrEqualTo(1100.0));
    }
  });

  test('同一窗口内取最高音：先 G4 后 G5，字母变成 G5', () {
    final d = PitchDetector();
    expect(_feed(d, 392.0), isTrue);
    expect(d.note, 'G4');

    expect(_feed(d, 784.0), isTrue);
    expect(d.note, 'G5', reason: '更高的音应当覆盖低音');
  });

  test('泛音丰富的低音不会跳到高次谐波（A3 合成器音色）', () {
    // 220Hz + 20 个谐波（1/k 幅度）：典型合成器 lead/pluck 的频谱。
    // 裸自相关会在 T/2、T/3… 的谐波峰上误判成 C8 之类的高音。
    final w = Float32List(2048);
    for (var i = 0; i < w.length; i++) {
      var v = 0.0;
      for (var k = 1; k <= 20; k++) {
        v += math.sin(2 * math.pi * 220 * k * i / 44100) / k;
      }
      w[i] = v * 0.12;
    }
    final d = PitchDetector();
    var locked = false;
    for (var f = 0; f < 5; f++) {
      locked = d.update(w) || locked;
    }
    expect(locked, isTrue);
    expect(d.note, 'A3', reason: '必须锁基频 220Hz，不能跳到高次谐波');
  });

  test('基频缺失（只有 2–10 次谐波）也能锁到真实周期', () {
    final w = Float32List(2048);
    for (var i = 0; i < w.length; i++) {
      var v = 0.0;
      for (var k = 2; k <= 10; k++) {
        v += math.sin(2 * math.pi * 220 * k * i / 44100) / k;
      }
      w[i] = v * 0.15;
    }
    final d = PitchDetector();
    var locked = false;
    for (var f = 0; f < 5; f++) {
      locked = d.update(w) || locked;
    }
    expect(locked, isTrue);
    expect(d.note, 'A3');
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


  /* ---------------- 人声 / 乐器 双档 ---------------- */

  test('人声档：混着很响的贝斯也能锁到人声 A3', () {
    final d = PitchDetector.vocal();
    // 55Hz 贝斯（响度是人声的 3 倍）+ 220Hz 人声（含 6 个谐波）
    final w = Float32List(2048);
    for (var i = 0; i < w.length; i++) {
      var voice = 0.0;
      for (var k = 1; k <= 6; k++) {
        voice += math.sin(2 * math.pi * 220 * k * i / 44100) / k;
      }
      w[i] = 0.10 * voice + 0.30 * math.sin(2 * math.pi * 55 * i / 44100);
    }
    var locked = false;
    for (var f = 0; f < 6; f++) {
      locked = d.update(w) || locked;
    }
    expect(locked, isTrue);
    expect(d.note, 'A3', reason: '人声档不能被贝斯带跑，也不能跳八度');
  });

  test('人声档：跟随旋律变化（E4 → G4），不是只取最高音', () {
    final d = PitchDetector.vocal();
    expect(_feed(d, 329.63, frames: 4), isTrue);
    expect(d.note, 'E4');

    // 换到更高的音：应当跟过去（不是「已经锁了最高就不动」）
    // 人声档要求连续 4 帧才算换音，所以喂 5 帧
    expect(_feed(d, 392.0, frames: 5), isTrue);
    expect(d.note, 'G4');

    // 再往低走：人声档也要跟下来
    expect(_feed(d, 261.63, frames: 5), isTrue);
    expect(d.note, 'C4');
  });

  test('人声档换音要稳 4 帧：只闪 2 帧的泛音不跳字，第 4 帧才换', () {
    final d = PitchDetector.vocal();
    expect(_feed(d, 329.63, frames: 4), isTrue);
    expect(d.note, 'E4');

    // 高八度的偶发泛音只持续 2 帧 → 不改字
    expect(_feed(d, 659.25, frames: 2), isFalse);
    expect(d.note, 'E4');

    // 真的换了音：继续同音喂到第 4 帧应当切过去
    expect(_feed(d, 659.25, frames: 3), isTrue);
    expect(d.note, 'E5');
  });

  test('人声档：单独的低频贝斯（60Hz）不锁', () {
    final d = PitchDetector.vocal();
    expect(_feed(d, 60, frames: 6), isFalse);
    expect(d.note, isNull);
  });

  test('乐器档：响贝斯盖不住 1kHz 的 lead', () {
    final d = PitchDetector();
    final w = Float32List(2048);
    for (var i = 0; i < w.length; i++) {
      var lead = 0.0;
      for (var k = 1; k <= 4; k++) {
        lead += math.sin(2 * math.pi * 1046.5 * k * i / 44100) / k;
      }
      // 贝斯比 lead 响一倍
      w[i] = 0.09 * lead + 0.22 * math.sin(2 * math.pi * 55 * i / 44100);
    }
    var locked = false;
    for (var f = 0; f < 6; f++) {
      locked = d.update(w) || locked;
    }
    expect(locked, isTrue);
    expect(d.note, 'C6');
  });

  test('乐器档：快速瞬态（每帧换音）也能逐帧捕捉', () {
    // 0.2s 一个音、连续上行：模拟快速 pluck 音阶
    final d = PitchDetector();
    final notes = <String>[];
    for (final hz in [523.25, 587.33, 659.25, 783.99]) {
      for (var f = 0; f < 2; f++) {
        d.update(_sine(hz, amp: 0.2));
      }
      notes.add(d.note ?? '-');
    }
    expect(notes, ['C5', 'D5', 'E5', 'G5'], reason: '每 2 帧一个音也要跟上');
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
