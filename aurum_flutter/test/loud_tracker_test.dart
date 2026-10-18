// 无歌词曲目的「持续响度最大段」（drop）跟踪：预热 / 进入 / 退出 / 重置。
import 'package:aurum/effects/pitch_detector.dart';
import 'package:flutter_test/flutter_test.dart';

const double _dt = 1 / 60;

void _feed(LoudSectionTracker t, double rms, double seconds) {
  final n = (seconds / _dt).round();
  for (var i = 0; i < n; i++) {
    t.update(rms, _dt);
  }
}

void main() {
  test('预热期内不激活（避免 intro 就亮）', () {
    final t = LoudSectionTracker();
    _feed(t, 0.02, 2);
    expect(t.active, isFalse);
  });

  test('持续响 → 激活；掉到门槛以下 2.5s → 退出；再起 drop → 重新激活', () {
    final t = LoudSectionTracker();
    _feed(t, 0.02, 6);
    expect(t.active, isTrue, reason: '高过峰值的 55% 且持续 0.8s 应激活');

    _feed(t, 0.002, 4);
    expect(t.active, isFalse, reason: '远低于门槛应退出');

    _feed(t, 0.3, 2);
    expect(t.active, isTrue, reason: 'drop 比之前更响，应重新激活');
    expect(t.peak, closeTo(0.3, 0.02));
  });

  test('reset 清空峰值与状态', () {
    final t = LoudSectionTracker();
    _feed(t, 0.3, 6);
    expect(t.active, isTrue);
    t.reset();
    expect(t.active, isFalse);
    expect(t.peak, 0);
    _feed(t, 0.02, 2);
    expect(t.active, isFalse, reason: '重置后重新走预热');
  });
}
