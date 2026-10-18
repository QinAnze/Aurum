/// Kick（底鼓）检测：中低频的快速冲击。
///
/// 思路：取 FFT 低频频段（约 20–150 Hz）的能量均值，跟一条**慢速基线**比。
/// kick 是「瞬间远高于稳态」的短促冲击，所以判据是三条同时成立：
///   1. 相对跃升：low > 基线 × ratio
///   2. 相对标尺：low > 本曲低频峰值 × peakFloor（安静段落不把噪声当鼓）
///   3. 不应期：上次命中后 refractory 秒内不再触发（一次鼓点只亮一次）
///
/// 输出 [env] 供画面使用：命中瞬间 = 1，之后按指数回落（帧率无关）。
library;

import 'dart:math' as math;
import 'dart:typed_data';

class KickDetector {
  KickDetector({
    this.lowBinFrom = 1,
    this.lowBinTo = 6,
    this.ratio = 1.45,
    this.riseRatio = 1.10,
    this.peakFloor = 0.075,
    this.absFloor = 2e-4,
    this.refractory = 0.11,
    this.envTau = 0.13,
    this.baselineTau = 0.40,
    this.warmupFrames = 20,
  });

  /// 低频频段（bin 下标，含端点）。FFT 窗 2048、44.1/48kHz 时
  /// bin1 ≈ 21Hz、bin6 ≈ 130–140Hz，正好覆盖底鼓基频。
  final int lowBinFrom;
  final int lowBinTo;

  /// 相对慢速基线的跃升倍数
  final double ratio;
  /// 相对上一帧的上升倍数（必须还在爬升才叫「冲击」；
  /// 持续低频长音在基线跟上后就贴平了，不会反复闪）
  final double riseRatio;
  /// 相对本曲低频峰值的比例门槛
  final double peakFloor;
  /// 绝对底噪门槛（线性幅度）
  final double absFloor;
  /// 不应期（秒）
  final double refractory;
  /// 包络回落时间常数（秒）
  final double envTau;
  /// 慢速基线时间常数（秒）
  final double baselineTau;
  /// 预热帧数：先学两三百毫秒的底噪，别让第一帧就误报
  final int warmupFrames;

  /// 画面用包络：命中瞬间 1，之后指数回落
  double env = 0;

  double _base = 0;
  double _peak = 0;
  double _since = 99;
  double _prevLow = 0;
  int _warm = 0;

  /// 每帧喂一次，返回本帧是否判定为 kick。
  ///
  /// [fft] 为线性幅度谱（flutter_soloud 原样）；
  /// [active] = 正在播放且特效开关开着；false 时只让包络回落。
  bool update(Float32List? fft, double dt, {bool active = true}) {
    dt = dt.clamp(0.0, 0.1); // 掉帧/切回前台时别让 dt 爆掉
    env *= math.exp(-dt / envTau);
    _since += dt;

    var low = 0.0;
    if (active && fft != null && fft.length > lowBinTo) {
      var sum = 0.0;
      var n = 0;
      for (var i = lowBinFrom; i <= lowBinTo && i < fft.length; i++) {
        sum += fft[i].abs();
        n++;
      }
      if (n > 0) low = sum / n;
    }

    // 慢速基线：跟随稳态低频。kick 的瞬间冲击会远高于它。
    final k = 1 - math.exp(-dt / baselineTau);
    _base += (low - _base) * k;
    // 峰值保持 + 极慢回落（半衰期约 40s），当跨段落的相对标尺
    _peak = math.max(low, _peak * math.exp(-dt / 60.0));

    if (!active) {
      _warm = 0;
      return false;
    }
    if (_warm < warmupFrames) {
      _warm++;
      _prevLow = low;
      return false;
    }
    final prev = _prevLow;
    _prevLow = low;

    if (_since < refractory) return false;
    if (low <= absFloor) return false;
    if (low <= _peak * peakFloor) return false;
    if (low <= _base * ratio) return false;
    // 必须是上升沿：持续低频（贝斯长音）在基线跟上后 rise≈1，不会再触发
    if (low <= prev * riseRatio) return false;

    env = 1;
    _since = 0;
    return true;
  }

  /// 清零（暂停、关特效、切歌时调用）
  void reset() {
    env = 0;
    _base = 0;
    _peak = 0;
    _since = 99;
    _prevLow = 0;
    _warm = 0;
  }
}
