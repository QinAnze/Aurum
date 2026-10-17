/// Aurum · 可视化主控制器（对应原版 vizLoop）。
/// 单一 Ticker 驱动全部逐帧特效：
///  - 真实响度 RMS → loudMax 峰值保持 → climax 高潮因子
///  - 频谱对数分 bin + 非对称平滑（120 点闭合曲线用）
///  - 封面绑定抖动（drift + 高潮随机 + 旋摆）
///  - 歌名/歌手发光 + 非线性放大 + 跷跷板摆动
///  - 背后词云整体放大/抖动 + 播放进度驱动出场
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../audio/player_engine.dart';
import '../../models.dart';
import 'spectrum_ring.dart' show kSpecN;
import 'word_cloud.dart';

class VizController extends ChangeNotifier implements TickerProvider {
  VizController({
    required this.engine,
    required this.isPlaying,
    required this.volume,
    required this.fxOn,
    required this.lyrics,
    required this.cloudColorsFn,
    required this.cloud,
  });

  final PlayerEngine engine;
  final bool Function() isPlaying;
  final double Function() volume;
  /// 视觉特效总开关（词云/频谱/超频 合一，对应原版 masterToggle）
  final bool Function() fxOn;
  final List<LyricLine> Function() lyrics;
  final List<Color> Function() cloudColorsFn;
  final WordCloudController cloud;

  /* ---------------- 对外暴露的逐帧状态 ---------------- */
  double climax = 0;
  final List<double> specVals = List.filled(kSpecN, 0.0);

  /// 封面绑定抖动（px / deg）
  double shakeDx = 0, shakeDy = 0, shakeRot = 0;

  /// 歌名/歌手容器：缩放 / 跷跷板角度(deg) / 光晕强度 / 光晕半径
  double npScale = 1, npAngle = 0, npGlow = 0, npBlur = 0;

  /// 词云画布整体变换
  double cloudScale = 1, cloudJx = 0, cloudJy = 0;

  /* ---------------- 内部 ---------------- */
  final math.Random _rng = math.Random();
  double loudMax = 0;
  double shakePhase = 0;
  /// 频谱峰值（自适应标度用）+ 取数缓冲区
  double _specPeak = 0;
  final Float64List _magBuf = Float64List(kSpecN);
  Ticker? _ticker;
  Duration? _lastElapsed;
  /// 累计播放时钟（秒）：驱动歌名跷跷板/BPM 回退的连续振荡。
  /// 用 ticker 累计而非 DateTime.now()，保证单调、不受系统时间跳变影响。
  double _tsec = 0;
  Size _canvasSize = Size.zero;
  Rect? _coverRect;

  /// 由词云 widget 在布局时回填（画布即视口大小）
  void setCanvasSize(Size size) => _canvasSize = size;

  /// 由封面 widget 回填其全局矩形（词云封面圆禁区）
  void setCoverRect(Rect? rect) => _coverRect = rect;

  @override
  Ticker createTicker(TickerCallback onTick) => Ticker(onTick);

  bool get running => _ticker?.isActive ?? false;

  void start() {
    final t = _ticker ??= createTicker(_tick);
    if (!t.isActive) {
      _lastElapsed = null;
      t.start();
    }
  }

  /// 歌词切换：重置词云（对应原版 setLyrics → cloudReset）
  void resetCloud() => cloud.reset();

  bool _shouldRun() {
    if (isPlaying() || engine.isPlaying) return true;
    if (fxOn()) return true; // 频谱/词云开着就持续渲染
    if (climax >= 0.02) return true; // 高潮余韵
    if (cloud.hasActive) return true; // 词还在坠落
    return false;
  }

  void _tick(Duration elapsed) {
    final dt = _lastElapsed == null
        ? 0.016
        : (elapsed - _lastElapsed!).inMicroseconds / 1e6;
    _lastElapsed = elapsed;
    _tsec += dt;

    // 以引擎为最终事实源：UI 状态偶发失同步时频谱也不该停摆
    final playing = isPlaying() || engine.isPlaying;
    final vol = volume();
    final oc = fxOn();
    final tsec = _tsec;

    // 真实频谱数据；全零（污染/无信号）则回退 BPM 模拟
    final fft = engine.fft;
    final wave = engine.wave;
    var real = false;
    if (fft != null && playing && fft.isNotEmpty) {
      var sum = 0.0;
      for (var i = 0; i < 16 && i < fft.length; i++) {
        sum += fft[i];
      }
      real = sum > 0;
    }

    /* ---- 高潮因子：峰值保持 + 相对阈值（intro 安静不抖，drop 持续抖）---- */
    if (oc) {
      var inst = 0.0;
      if (real && wave != null && wave.isNotEmpty) {
        var sum = 0.0;
        for (final v in wave) {
          sum += v * v;
        }
        inst = math.min(1, math.sqrt(sum / wave.length) * 2.8);
      } else if (playing && vol > 0) {
        inst = 0.12; // 无真实信号时的模拟底
      }
      if (inst > loudMax) {
        loudMax = inst; // 捕获全曲最响的持续响度
      } else {
        loudMax = math.max(inst, loudMax * 0.9997); // 极慢回落
      }
      final pos = inst / (loudMax + 0.001); // 本曲内响度位置
      var c = ((pos - 0.72) / 0.28).clamp(0.0, 1.0);
      c = c * c * (3 - 2 * c); // smoothstep
      if (loudMax < 0.26) c = 0; // 门槛：须出现过真正响的段落
      climax += (c - climax) * (c > climax ? 0.34 : 0.06); // 起快落慢
      if (!playing) climax *= 0.92;
    } else {
      climax *= 0.85;
    }

    /* ---- 歌名/歌手：文字光晕（与 climax 成正比连续淡出）+ 放大 + 跷跷板 ---- */
    if (oc) {
      npScale = 1 + math.pow(climax, 0.7) * 0.65;
      final swing = math.sin(tsec * 2.6); // ~2.4s 一周期
      final swingEased = swing.sign * math.pow(swing.abs(), 1.35);
      npAngle = swingEased * 4 * math.pow(climax, 0.8);
      npGlow = math.min(1, climax * 1.3);
      npBlur = climax * 36;
    } else {
      npScale = 1;
      npAngle = 0;
      npGlow = 0;
      npBlur = 0;
    }

    /* ---- 背后词云：随高潮整体非线性放大 + 同步轻微抖动 ---- */
    if (oc && climax > 0.01) {
      cloudScale = 1 + math.pow(climax, 0.8) * 0.06;
      cloudJx = (_rng.nextDouble() - 0.5) * climax * 2;
      cloudJy = (_rng.nextDouble() - 0.5) * climax * 2;
    } else {
      cloudScale = 1;
      cloudJx = 0;
      cloudJy = 0;
    }

    /* ---- 绑定抖动：封面 + 频谱作为一个整体 ---- */
    if (oc) {
      final driftFreq = 0.7 + climax * 2.6;
      shakePhase += dt * driftFreq;
      final base = 0.4 + climax * 0.7;
      final jit = climax * 9;
      shakeDx = math.sin(shakePhase * 2.1) * base +
          math.sin(shakePhase * 5.7) * base * 0.35 +
          (_rng.nextDouble() - 0.5) * jit;
      shakeDy = math.cos(shakePhase * 1.7) * base +
          math.cos(shakePhase * 4.3) * base * 0.35 +
          (_rng.nextDouble() - 0.5) * jit;
      shakeRot = math.sin(shakePhase * 1.3) * (climax * 0.5);
    } else {
      shakeDx = 0;
      shakeDy = 0;
      shakeRot = 0;
    }

    /* ---- 频谱取数 + 非对称平滑（对数分 bin + 自适应峰值 + gamma）----
       注意：Web 的 getByteFrequencyData 是 **dB 映射后的 0~255 字节值**，
       而 flutter_soloud 给的是**线性幅度**（音乐常见 0.001~0.3）。
       直接按 /255 等价换算会让曲线幅度只有 1px，看起来就是一条死平的环。
       这里跟踪本帧峰值做相对归一化 + gamma 提亮低幅 bin，任何标度都能用满量程。 */
    if (fxOn()) {
      final mags = _magBuf;
      var peak = 0.0;
      for (var i = 0; i < kSpecN; i++) {
        double m = 0;
        if (real && fft != null) {
          final bin = 2 +
              (math.pow(i / kSpecN, 1.15) * (fft.length - 4) * 0.65).floor();
          if (bin < fft.length) m = fft[bin].abs();
        } else if (playing && vol > 0) {
          final beat =
              math.pow(math.sin(tsec * math.pi * (128 / 60) + i * 0.6).abs(), 1.6);
          final wob = 0.5 + 0.5 * math.sin(tsec * 1.7 + i * 1.31);
          m = (0.12 + 0.88 * beat) * (0.35 + 0.65 * wob);
        }
        mags[i] = m;
        if (m > peak) peak = m;
      }
      // 峰值缓慢回落，避免爆点过后长期压扁
      if (peak > _specPeak) {
        _specPeak = peak;
      } else {
        _specPeak = math.max(peak, _specPeak * 0.9995);
      }
      final inv = _specPeak > 1e-9 ? 1.0 / _specPeak : 0.0;
      for (var i = 0; i < kSpecN; i++) {
        final norm = mags[i] * inv; // 0..1 相对峰值
        final t = norm <= 0 ? 0.0 : math.min(1.0, math.pow(norm, 0.55) * 1.15);
        specVals[i] += (t - specVals[i]) * (t > specVals[i] ? 0.82 : 0.20);
      }
    }

    /* ---- 词云：播放进度驱动出场 + 生命周期推进 ---- */
    if (fxOn() && _canvasSize != Size.zero) {
      cloud.tick(
        engine.positionSec,
        CloudEnv(
          on: true,
          lyrics: lyrics(),
          size: _canvasSize,
          colors: cloudColorsFn(),
          overclock: true,
          climax: climax,
          coverRect: _coverRect,
        ),
      );
      cloud.advance();
    }

    /* ---- 收尾：暂停且无频谱时淡出后停帧 ---- */
    if (!_shouldRun()) {
      _ticker?.stop();
      _lastElapsed = null;
      shakeDx = 0;
      shakeDy = 0;
      shakeRot = 0;
      npScale = 1;
      npAngle = 0;
      npGlow = 0;
      npBlur = 0;
      cloudScale = 1;
      cloudJx = 0;
      cloudJy = 0;
      notifyListeners();
      return;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }
}
