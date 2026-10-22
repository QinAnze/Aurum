/// Aurum · 声像（立体声宽度）检测。
///
/// 用左右声道的 mid/side 能量比估「声场有多宽」：
///  - **mid** = (L+R)/2 —— 两声道相同的成分，听感上钉在正中间
///  - **side** = (L-R)/2 —— 只有左右不同的成分，撑开声场的那部分
///  - `side / (mid + side)`：单声道 ≈ 0，纯反相 ≈ 1
///
/// 真实混音的比值大多落在 0.05–0.45 之间，直接拿来用会「一直很窄」。
/// 所以除以 [_kNorm] 归一化 —— 到 0.5 就算打满，这才够灵敏。
///
/// 平滑用「起快落慢」：声场一张开要立刻跟上，收回去时慢慢退，
/// 否则颗粒会一惊一乍地抖。
library;

import 'dart:math' as math;
import 'dart:typed_data';

class ImagerDetector {
  /// 当前声像宽度 0..1（0 = 完全单声道，1 = 极宽）
  double width = 0;

  /// 未平滑的瞬时值（调试/测试用）
  double raw = 0;

  /// side/(mid+side) 达到这个值就算「最宽」。
  /// 0.5 是刻意偏小的 —— 用户要灵敏，不能等真的反相才动。
  static const double _kNorm = 0.5;

  /// 起快落慢
  static const double _kAttack = 0.65;
  static const double _kRelease = 0.12;

  /// 能量低于这个就当作「没声音」，别让底噪把颗粒吹开
  static const double _kSilence = 1.5e-4;

  /// 每帧推进一次。引擎不支持分声道（或单声道文件）时 [l]/[r] 为 null。
  void update(Float32List? l, Float32List? r, {required bool active}) {
    if (!active || l == null || r == null || l.isEmpty || r.isEmpty) {
      _decay();
      return;
    }
    final n = math.min(l.length, r.length);
    var sumM = 0.0;
    var sumS = 0.0;
    for (var i = 0; i < n; i++) {
      final a = l[i];
      final b = r[i];
      final m = (a + b) * 0.5;
      final s = (a - b) * 0.5;
      sumM += m * m;
      sumS += s * s;
    }
    final mid = math.sqrt(sumM / n);
    final side = math.sqrt(sumS / n);
    final total = mid + side;
    if (total < _kSilence) {
      _decay();
      return;
    }
    final target = ((side / total) / _kNorm).clamp(0.0, 1.0);
    raw = target;
    width += (target - width) * (target > width ? _kAttack : _kRelease);
    width = width.clamp(0.0, 1.0);
  }

  void _decay() {
    raw *= 0.9;
    width *= 0.92;
    if (width < 1e-4) width = 0;
  }

  void reset() {
    width = 0;
    raw = 0;
  }
}
