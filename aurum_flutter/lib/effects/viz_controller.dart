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
import 'kick_detector.dart';
import 'pitch_detector.dart';
import 'pitch_scatter.dart';
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
    this.coverPaletteFn,
    this.fxCloud,
    this.fxSpectrum,
    this.fxKick,
    this.fxPitch,
  });

  final PlayerEngine engine;
  final bool Function() isPlaying;
  final double Function() volume;
  /// 视觉特效总开关（masterToggle）：关掉时所有特效一起停
  final bool Function() fxOn;
  final List<LyricLine> Function() lyrics;
  final List<Color> Function() cloudColorsFn;
  final WordCloudController cloud;

  /// 封面原始取色板（未提亮、未掺色）。音高散落字的颜色直接取自这里；
  /// 不传则退回 [cloudColorsFn]。
  final List<Color> Function()? coverPaletteFn;

  /// 逐特效开关（可选；未传则跟随总开关）。总开关关闭时一律不生效。
  ///  - [fxCloud]    背景词云
  ///  - [fxSpectrum] 封面频谱环
  ///  - [fxKick]     四周打光
  ///  - [fxPitch]    音高字母（人声中央字母 + 乐器段底部散落）
  final bool Function()? fxCloud;
  final bool Function()? fxSpectrum;
  final bool Function()? fxKick;
  final bool Function()? fxPitch;

  /// 词云是否该跑
  bool cloudEnabled() => fxOn() && (fxCloud?.call() ?? true);
  /// 频谱是否该取数/绘制
  bool spectrumEnabled() => fxOn() && (fxSpectrum?.call() ?? true);
  /// 打光是否该跑
  bool kickEnabled() => fxOn() && (fxKick?.call() ?? true);
  /// 音高检测 + 字母是否该跑
  bool pitchEnabled() => fxOn() && (fxPitch?.call() ?? true);

  /* ---------------- 对外暴露的逐帧状态 ---------------- */
  double climax = 0;
  final List<double> specVals = List.filled(kSpecN, 0.0);

  /// 底鼓检测器：中低频快速冲击 → 窗口四周打光（kick.env 即强度包络）
  final KickDetector kick = KickDetector();

  /// 乐器音高：窗口内取最高的音（lead / guitar / pluck / color bass）
  final PitchDetector pitch = PitchDetector();

  /// 人声音高：歌词段跟着旋律走（不是取最高，是当前这个音）
  final PitchDetector vocal = PitchDetector.vocal();

  /// 逐帧决定跑人声还是乐器（歌词段 → 人声；>8s 的纯乐器段 → 乐器）
  final PitchWindow window = PitchWindow();

  /// 乐器段的散落字母（底部随机落位、无动画、无光晕）。
  /// 人声段不用它：那一段还是封面中央的 [PitchBadge]。
  final PitchScatterController scatter = PitchScatterController();

  /// 无歌词曲目 / 前奏：持续响度最大段（drop）跟踪
  final LoudSectionTracker loud = LoudSectionTracker();

  /// 上一次的播放位置：用于识别切歌/回跳并重置跟踪
  double _lastPos = 0;

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

  /// 进入「无歌词 / 超长句 8s 后」相位的时刻（ticker 时钟）。
  /// 用来算交接期：中心字母与背景词云先落下去，之后才允许铺背景散落。
  double _instrumentAt = -1e9;

  /// 交接期时长：中央字母坠落 380ms、词云 480ms，取 0.5s 两边都落完。
  static const double _kHandoverSec = 0.5;

  /// 交接时词云的坠落时长（ms）。正常换行是 1150ms，这里催快一点。
  static const double _kCloudFallMs = 480;

  /// 由词云 widget 在布局时回填（画布即视口大小）
  void setCanvasSize(Size size) {
    _canvasSize = size;
    scatter.layout(size);
  }

  /// 由封面 widget 回填其全局矩形（词云封面圆禁区）
  void setCoverRect(Rect? rect) => _coverRect = rect;

  /// 封面全局矩形（音高字母落点）
  Rect? get coverRect => _coverRect;

  /// 散落字被吸向哪里：封面中心；封面还没布局出来就退到画布中心
  Offset _suckTarget() {
    final r = _coverRect;
    if (r != null && !r.isEmpty) return r.center;
    if (_canvasSize.isEmpty) return Offset.zero;
    return Offset(_canvasSize.width / 2, _canvasSize.height / 2);
  }

  /// 当前该显示的音名：**只在人声段**有值（封面中央那个字母）。
  /// 乐器段改走背景散落（[scatter]），两者不会同时出现。
  String? get pitchNote => switch (window.phase) {
        // 散落还在被吸向中心时先不显示：让"吸进去"这一个动作演完，
        // 中央字母再接上，否则两段会同时出现在同一帧，看着像打架。
        // 唱完静 0.6s 也让字母落下去（>8s 段落前先收，段开始再升上来）。
        PitchPhase.vocal =>
          (scatter.sucking || window.silence > 0.6) ? null : vocal.note,
        PitchPhase.instrument => null,
        PitchPhase.off => null,
      };

  /// 是否该显示音高字母
  bool get pitchVisible => pitchNote != null;

  /// 音名变化计数（驱动弹出动画）
  int get pitchRevision => switch (window.phase) {
        PitchPhase.vocal => vocal.revision,
        PitchPhase.instrument => pitch.revision,
        PitchPhase.off => 0,
      };

  /// 一帧波形的线性 RMS（响度段跟踪用）
  static double _waveRms(Float32List? w) {
    if (w == null || w.isEmpty) return 0;
    var sum = 0.0;
    for (final v in w) {
      sum += v * v;
    }
    return math.sqrt(sum / w.length);
  }

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
    if (cloudEnabled() || spectrumEnabled()) return true; // 词云/频谱开着就持续渲染
    if (climax >= 0.02) return true; // 高潮余韵
    if (kick.env >= 0.01) return true; // 打光余晖还要淡出
    if (cloud.hasActive) return true; // 词还在坠落
    if (!scatter.isEmpty) return true; // 散落字母还要留在屏上
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
    final pc = oc && pitchEnabled();
    final tsec = _tsec;

    // 真实频谱数据；无信号则回退 BPM 模拟。
    // 不要用「FFT 前几个 bin 之和 > 0」判有没有信号：那些 bin ≈ 低频，
    // 纯高频 lead 段落里可以是 0，会把音高/kick 检测整体关掉。改看波形能量。
    final fft = engine.fft;
    final wave = engine.wave;
    var real = false;
    if (playing && wave != null && wave.isNotEmpty) {
      var sum = 0.0;
      for (final v in wave) {
        sum += v * v;
      }
      real = math.sqrt(sum / wave.length) > 1e-4; // -80dBFS 以上算有信号
    }

    /* ---- 底鼓检测：只在播放 + 特效开关打开时判，否则让包络自然回落 ----
       数据源用 wave（时域、线性幅度）：fft 是 dB 归一化 0..1，低频段
       长期饱和在 1.0，判不了冲击（详见 kick_detector 顶部注释）。 */
    kick.update(real ? wave : null, dt, active: kickEnabled() && playing && real);

    /* ---- 音高：歌词段测人声（中央字母），>8s 的纯乐器段测乐器（底部散落）---- */
    final pos = engine.positionSec;
    if (pos < _lastPos - 1.0) {
      // 切歌 / 回跳：响度统计与已锁定的音全部重来
      loud.reset();
      pitch.reset();
      vocal.reset();
      window.reset();
      scatter.clear();
    }
    _lastPos = pos;

    if (pc) {
      final lines = lyrics();
      if (playing) loud.update(_waveRms(wave), dt);

      final prevPhase = window.phase;
      // 人声只在人声相位跑（省一半算力）；本帧测没测到音用来判断「唱完了」
      var heard = false;
      if (prevPhase == PitchPhase.vocal && playing && real) {
        vocal.update(wave, active: true);
        heard = vocal.lastValid;
      }
      final phase = window.update(
        lines: lines,
        pos: pos,
        dt: dt,
        playing: playing,
        vocalHeard: heard,
        loudActive: loud.active,
      );
      if (phase != prevPhase) {
        // 换相位就清空对应检测器：新窗口从零开始取音
        if (phase == PitchPhase.vocal) vocal.reset();
        if (phase == PitchPhase.instrument) pitch.reset();
        if (phase == PitchPhase.vocal) {
          // 散落 → 中央：把屏上的字**吸向封面中心**，吸完才出中央字母。
          // 直接 clear 会让背景"啪"地空掉、字母凭空冒出来，两段接不上。
          scatter.suckTo(_suckTarget());
        } else if (phase == PitchPhase.instrument) {
          // 歌词段 → 无歌词段（含超长句唱过 8s）：中央字母和背景歌词先让位。
          //  - 中央字母：pitchNote 变 null，PitchBadge 自己播 380ms 坠落
          //  - 背景词云：让当前这句立刻错落坠落（480ms，比正常换行更快）
          //  - 平铺：延后 [_kHandoverSec] 再开铺，绝不和上面两个同框
          scatter.cancelSuck();
          _instrumentAt = _tsec;
          cloud.dropCurrent(fallMs: _kCloudFallMs);
        } else {
          scatter.clear();
        }
      }
      // 散落的入场/吸走动画要逐帧推进（字落位之后本身是静态的）
      scatter.tick(dt);
      // 交接期：中心音高还在往下落（380ms），词云也在落（480ms），
      // 这段时间不放新的平铺字，否则三个元素会糊在一起。
      final settled = _tsec - _instrumentAt >= _kHandoverSec;
      if (phase == PitchPhase.instrument && playing && real && settled) {
        final rev = pitch.revision;
        if (pitch.update(wave, active: true) && pitch.revision != rev) {
          final note = pitch.note;
          if (note != null) {
            // 颜色取自封面原始色板（不走 cloudColors：那套会掺固定粉彩 + 提亮，
            // 撒出来的字就全变成差不多的白，看不出封面配色）。
            final pal = coverPaletteFn?.call();
            scatter.setPalette((pal != null && pal.isNotEmpty)
                ? pal
                : cloudColorsFn());
            if (scatter.viewport.isEmpty) scatter.layout(_canvasSize);
            final ok = scatter.spawn(note);
            // 满屏清空后立刻补上这一个：清空那一帧的字不该丢
            if (!ok && scatter.isEmpty) {
              scatter.layout(_canvasSize);
              scatter.spawn(note);
            }
          }
        }
      }
    } else {
      window.reset();
      loud.reset();
      pitch.reset();
      vocal.reset();
      scatter.clear();
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
    if (spectrumEnabled()) {
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
    if (cloudEnabled() && _canvasSize != Size.zero) {
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
    // 注意：散落字母一旦落位就是静态的，不需要逐帧推进 ——
    // 只要没有别的特效要跑，就停帧把它们留在屏上（切歌/换相位时才清）。
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
      kick.reset();
      window.reset();
      loud.reset();
      pitch.reset();
      vocal.reset();
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
