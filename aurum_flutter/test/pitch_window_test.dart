// 相位调度回归：歌词段测人声 / >8s 的纯乐器段测乐器 / 无歌词靠响度段。
import 'package:aurum/effects/pitch_detector.dart';
import 'package:aurum/models.dart';
import 'package:flutter_test/flutter_test.dart';

List<LyricLine> _lines(List<double> ts) =>
    [for (final t in ts) LyricLine(t: t, text: 'line $t')];

/// 以 [dt] 步长把播放位置推到 [to]，期间人声是否测到音由 [heardUntil] 决定。
PitchPhase _run(
  PitchWindow w,
  List<LyricLine> lines, {
  required double from,
  required double to,
  double heardUntil = double.infinity,
  bool playing = true,
  bool loudActive = false,
  double dt = 0.05,
}) {
  var phase = w.phase;
  var pos = from;
  while (pos < to) {
    pos += dt;
    phase = w.update(
      lines: lines,
      pos: pos,
      dt: dt,
      playing: playing,
      vocalHeard: pos <= heardUntil,
      loudActive: loudActive,
    );
  }
  return phase;
}

void main() {
  test('歌词段：一开始就用人声', () {
    final w = PitchWindow();
    final phase = _run(w, _lines([0, 30]), from: 0, to: 1, heardUntil: 1);
    expect(phase, PitchPhase.vocal);
  });

  test('间隔 >8s 且人声停了 1.2s：切成乐器', () {
    final w = PitchWindow();
    final lines = _lines([0, 20]);
    // 前 1.5s 还在唱
    expect(_run(w, lines, from: 0, to: 1.5, heardUntil: 1.5), PitchPhase.vocal);
    // 唱完之后继续走 1s：还没到 2s 沉默门槛
    expect(_run(w, lines, from: 1.5, to: 2.5, heardUntil: 1.5), PitchPhase.vocal);
    // 再走 1.2s：累计沉默 > 2s → 乐器
    expect(_run(w, lines, from: 2.5, to: 3.7, heardUntil: 1.5),
        PitchPhase.instrument);
  });

  test('间隔不足 8s：一直是人声，不会切乐器', () {
    final w = PitchWindow();
    final lines = _lines([0, 5]);
    expect(_run(w, lines, from: 0, to: 1, heardUntil: 1), PitchPhase.vocal);
    // 后面测不到音也不切（因为不是长间隙）
    expect(_run(w, lines, from: 1, to: 4.9, heardUntil: 1), PitchPhase.vocal);
  });

  test('下一句开始：从乐器切回人声', () {
    final w = PitchWindow();
    final lines = _lines([0, 12, 24]);
    _run(w, lines, from: 0, to: 1, heardUntil: 1);
    expect(_run(w, lines, from: 1, to: 6, heardUntil: 1), PitchPhase.instrument);
    // 第二句开始 → 回到人声
    expect(_run(w, lines, from: 6, to: 12.4, heardUntil: 12.4),
        PitchPhase.vocal);
  });

  test('无歌词：按持续响度段决定，响段结束就关', () {
    final w = PitchWindow();
    expect(_run(w, [], from: 0, to: 1), PitchPhase.off);
    expect(_run(w, [], from: 1, to: 2, loudActive: true),
        PitchPhase.instrument);
    expect(_run(w, [], from: 2, to: 3), PitchPhase.off);
  });

  test('第一句歌词之前（前奏）：也按响度段走', () {
    final w = PitchWindow();
    final lines = _lines([10, 30]);
    expect(_run(w, lines, from: 0, to: 2, loudActive: true),
        PitchPhase.instrument);
    // 进入第一句 → 人声
    expect(_run(w, lines, from: 8, to: 10.2, heardUntil: 10.2),
        PitchPhase.vocal);
  });

  test('暂停时不累计沉默（不会因为暂停就切乐器）', () {
    final w = PitchWindow();
    final lines = _lines([0, 20]);
    expect(_run(w, lines, from: 0, to: 0.5, heardUntil: 0.5), PitchPhase.vocal);
    expect(
      _run(w, lines, from: 0.5, to: 4.5, playing: false),
      PitchPhase.vocal,
      reason: '暂停 4s 不该被当成「唱完了」',
    );
  });

  test('reset 后回到关闭', () {
    final w = PitchWindow();
    _run(w, _lines([0, 20]), from: 0, to: 1, heardUntil: 1);
    expect(w.phase, PitchPhase.vocal);
    w.reset();
    expect(w.phase, PitchPhase.off);
  });
}
