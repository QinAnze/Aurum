/// Kick（底鼓）检测：中低频的快速冲击。
///
/// 数据源用**时域波形**而不是 FFT。
/// flutter_soloud 的 fft 是 dB 归一化到 0..1（minDb=-100 / maxDb=-30，
/// 见插件 src/analyzer.cpp），音乐里的贝斯/底鼓长期贴着 -30dB 上限
/// 饱和成 1.0，动态范围被压扁，比值类判据完全失效。
/// 波形是线性幅度，过两级一阶低通（≈130Hz）取 RMS，就得到干净的
/// 低频能量包络，判据在真实动态范围里做。
///
/// 判据（同时成立）：
///   1. 相对跃升：low > 慢速基线 × ratio
///   2. 上升沿：low > 上一帧 × riseRatio（压住持续贝斯长音）
///   3. 相对标尺：low > 本曲低频峰值 × peakFloor
///   4. 绝对底噪：low > absFloor
///   5. 不应期：一次鼓点只亮一次
library;

import 'dart:math' as math;
import 'dart:typed_data';

class KickDetector {
  KickDetector({
    this.cutoffHz = 300,
    this.sampleRate = 44100,
    this.ratio = 1.35,
    this.riseRatio = 1.06,
    this.peakFloor = 0.075,
    this.absFloor = 2e-3,
    this.refractory = 0.10,
    this.envTau = 0.13,
    this.baselineTau = 0.40,
    this.warmupFrames = 20,
  });

  /// 低通截止频率（两级一阶 ≈ 12dB/oct）。
  /// 取 300Hz：底鼓主体 50–100Hz，而不少电子乐/trap 的 kick 主峰在
  /// 150–250Hz，130Hz 会把它们削掉；贝斯的少量泄漏可以接受。
  final double cutoffHz;
  final double sampleRate;

  /// 相对慢速基线的跃升倍数
  final double ratio;
  /// 相对上一帧的上升倍数（必须还在爬升才叫「冲击」）
  final double riseRatio;
  /// 相对本曲低频峰值的比例门槛
  final double peakFloor;
  /// 绝对底噪门槛（低频 RMS，线性幅度）
  final double absFloor;
  /// 不应期（秒）
  final double refractory;
  /// 包络回落时间常数（秒）
  final double envTau;
  /// 慢速基线时间常数（秒）
  final double baselineTau;
  /// 预热帧数：先学两三百毫秒的底噪
  final int warmupFrames;

  /// 画面用包络：命中瞬间 1，之后指数回落
  double env = 0;

  /// 上一帧的低频 RMS（调试/测试可读）
  double low = 0;

  double _base = 0;
  double _peak = 0;
  double _since = 99;
  double _prevLow = 0;
  int _warm = 0;

  /// 一帧时域波形 → 低频（≈130Hz 以下）RMS。
  /// 跳过前 128 个样本让滤波器收敛（130Hz 时间常数约 1.2ms）。
  double lowRms(Float32List wave) {
    final a = math.exp(-2 * math.pi * cutoffHz / sampleRate);
    final b = 1 - a;
    var z1 = 0.0;
    var z2 = 0.0;
    var sum = 0.0;
    var n = 0;
    for (var i = 0; i < wave.length; i++) {
      z1 = b * wave[i] + a * z1;
      z2 = b * z1 + a * z2;
      if (i >= 128) {
        sum += z2 * z2;
        n++;
      }
    }
    return n == 0 ? 0 : math.sqrt(sum / n);
  }

  /// 每帧喂一次波形，返回本帧是否判定为 kick。
  ///
  /// [wave] 为时域样本（-1..1）；
  /// [active] = 正在播放且特效开关开着；false 时只让包络回落。
  bool update(Float32List? wave, double dt, {bool active = true}) {
    dt = dt.clamp(0.0, 0.1); // 掉帧/切回前台时别让 dt 爆掉
    env *= math.exp(-dt / envTau);
    _since += dt;

    final now = (active && wave != null && wave.isNotEmpty) ? lowRms(wave) : 0.0;
    low = now;

    // 慢速基线：跟随稳态低频。kick 的瞬间冲击会远高于它。
    final k = 1 - math.exp(-dt / baselineTau);
    _base += (now - _base) * k;
    // 峰值保持 + 极慢回落（半衰期约 40s），当跨段落的相对标尺
    _peak = math.max(now, _peak * math.exp(-dt / 60.0));

    if (!active) {
      _warm = 0;
      return false;
    }
    if (_warm < warmupFrames) {
      _warm++;
      _prevLow = now;
      return false;
    }
    final prev = _prevLow;
    _prevLow = now;

    if (_since < refractory) return false;
    if (now <= absFloor) return false;
    if (now <= _peak * peakFloor) return false;
    if (now <= _base * ratio) return false;
    if (now <= prev * riseRatio) return false;

    env = 1;
    _since = 0;
    return true;
  }

  /// 清零（暂停、关特效、切歌时调用）
  void reset() {
    env = 0;
    low = 0;
    _base = 0;
    _peak = 0;
    _since = 99;
    _prevLow = 0;
    _warm = 0;
  }
}
