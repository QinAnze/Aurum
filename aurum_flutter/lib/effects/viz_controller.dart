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
import 'imager_detector.dart';
import 'imager_field.dart';
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
    this.fxImager,
  });

  final PlayerEngine engine;
  final bool Function() isPlaying;
  final double Function() volume;
  /// 视觉特效总开关（masterToggle）：关掉时所有特效一起停
  final bool Function() fxOn;
  final List<LyricLine> Function() lyrics;
  final List<Color> Function() cloudColorsFn;
  final WordCloudController cloud;

  /// 声像（立体声宽度）检测
  final ImagerDetector imager = ImagerDetector();
  /// 声像颗粒场（最底层粒子）
  final ImagerFieldController imagerField = ImagerFieldController();

  /// 当前声像宽度 0..1
  double get imagerWidth => imager.width;

  /// 频谱此刻是否该显示。暂停 / 停止时置 false —— 直线频谱会淡出，
  /// 不会把暂停那一帧的旧值冻在封面上。
  bool specLive = false;

  /// 当前是否在播放。**暂停时所有"实时数据"特效都要收起来**
  /// （中央音高字母、背景平铺音高、直线频谱）：它们的数据停在最后一帧，
  /// 留着会像画面卡死。
  bool live = false;

  /// 音高显示是否该露出来（在播 + 开关打开）
  bool get pitchLive => live;

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
  final bool Function()? fxImager;

  /// 词云是否该跑
  bool cloudEnabled() => fxOn() && (fxCloud?.call() ?? true);
  /// 频谱是否该取数/绘制
  bool spectrumEnabled() => fxOn() && (fxSpectrum?.call() ?? true);
  /// 打光是否该跑
  bool kickEnabled() => fxOn() && (fxKick?.call() ?? true);
  /// 音高检测 + 字母是否该跑
  bool pitchEnabled() => fxOn() && (fxPitch?.call() ?? true);
  /// 声像颗粒是否该跑
  bool imagerEnabled() => fxOn() && (fxImager?.call() ?? true);

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

  /// 音高字（中央字母 + 背景平铺）的脉动：同一套 climax 驱动，
  /// 幅度比歌名小一档 —— 平铺字铺满整屏，放太大就会互相压。
  double pitchScale = 1, pitchGlow = 0, pitchBlur = 0;

  /// 词云画布整体变换
  double cloudScale = 1, cloudJx = 0, cloudJy = 0;

  /* ---------------- 内部 ---------------- */
  final math.Random _rng = math.Random();
  double loudMax = 0;
  double shakePhase = 0;
  /// 取数缓冲区
  final Float64List _magBuf = Float64List(kSpecN);

  /// 长期响度参考（近似 LUFS 的短窗平均）：频谱用它做归一化，
  /// 而不是每帧峰值 —— 峰值归一化会让每帧都有一个 bin 顶到 1.0。
  double _loudRef = 0;

  /* ---------------- 频谱频段划分 ---------------- */

  /// 频谱显示范围（Hz）。10Hz 以下多是直流/隆隆声，21000 已覆盖
  /// 44.1k 采样的整个可听带（奈奎斯特 22050，留 1k 余量）。
  static const double specLowHz = 10;
  static const double specHighHz = 21000;

  /// 采样率：flutter_soloud 默认输出 44.1k
  static const double _kSampleRate = 44100;

  /// 每个显示点对应的 FFT bin（按 fft 长度缓存）
  Int32List? _specBins;
  int _specBinN = -1;

  /// 频段划分的指数。**< 1 就是「低频粗、高频细」**：
  /// u = t^0.62 在开头涨得快 → 前 1/4 个点跨掉 4~5 个八度（低频每点一大片），
  /// 后 1/4 只跨 2 个八度（高频每点一小段）。
  /// 若用 1.0（标准对数谱）低频反而最细，与这里的观感诉求相反。
  static const double _kBandSkew = 0.62;

  /// 相对长期响度的余量：0.55 相当于整体先压低约 5dB 再看谱，
  /// 满量程素材才不会一路顶到上限。
  static const double _kSpecHeadroom = 0.55;

  /// dB 映射的下限：-40dB 以下一律压到 0
  static const double specFloorDb = -40;

  /// 幅度 → 0..1 的 dB 映射。
  ///
  /// [gain] 由长期响度参考算出（≈ headroom / loudRef），所以这是
  /// **相对整体响度**的谱，而不是每帧相对峰值 —— 后者会让每一帧
  /// 都有一个 bin 正好等于 1.0，曲线永远贴着顶部那条线。
  @visibleForTesting
  static double specLevel(double mag, double gain) {
    final x = mag * gain;
    if (x <= 1e-9) return 0;
    final db = 20 * (math.log(x) / math.ln10);
    return ((db - specFloorDb) / -specFloorDb).clamp(0.0, 1.0).toDouble();
  }

  @visibleForTesting
  static Int32List buildSpecBins(int fftLen) {
    final bins = Int32List(kSpecN);
    // fft 给的是 0..奈奎斯特的 magnitude，bin 宽 = 采样率/2/fftLen
    final binHz = (_kSampleRate / 2) / fftLen;
    final span = specHighHz / specLowHz;
    for (var i = 0; i < kSpecN; i++) {
      final t = i / (kSpecN - 1);
      final hz = specLowHz * math.pow(span, math.pow(t, _kBandSkew));
      bins[i] = (hz / binHz).round().clamp(0, fftLen - 1);
    }
    return bins;
  }

  /// 上升 / 回落系数：低频慢（0.30 / 0.08），高频快（0.92 / 0.34）。
  /// 低频拖住能量看起来"够厚"，高频跟手才看得见细节。
  static final Float64List _specAtk = _buildBandTau(0.30, 0.92);
  static final Float64List _specRel = _buildBandTau(0.08, 0.34);

  static Float64List _buildBandTau(double low, double high) {
    final out = Float64List(kSpecN);
    for (var i = 0; i < kSpecN; i++) {
      final t = i / (kSpecN - 1);
      out[i] = (low + (high - low) * math.pow(t, 0.75)).toDouble();
    }
    return out;
  }
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
        // 不播放就整个收起来：音名停在最后一帧，留着像卡死
        _ when !live => null,
        // 散落还在被吸向中心时先不显示：让"吸进去"这一个动作演完，
        // 中央字母再接上，否则两段会同时出现在同一帧，看着像打架。
        // 唱完静 0.6s 也让字母落下去（>8s 段落前先收，段开始再升上来）。
        PitchPhase.vocal =>
          (scatter.exiting || window.silence > 0.6) ? null : vocal.note,
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
    if (imagerEnabled()) return true; // 声像颗粒要一直流动
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
    live = playing;
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
      _loudRef = 0; // 新歌的响度基准重新建立
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
          scatter.cancelExit();
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

    /* ---- 音高字：与歌名同一套（climax 驱动发光 + 非线性放大）---- */
    if (oc) {
      pitchGlow = math.min(1, climax * 1.3);
      pitchBlur = climax * 22;
      // 幅度比歌名（0.65）小得多：平铺字铺满整屏，放到 1.35 就会糊成一片
      pitchScale = 1 + math.pow(climax, 0.7) * 0.24;
    } else {
      pitchGlow = 0;
      pitchBlur = 0;
      pitchScale = 1;
    }
    // 平铺只吃放大；发光只给中央字母（上百个字带阴影会卡）
    scatter.setPulse(pitchScale);

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

    /* ---- 频谱取数 + 分频段平滑（对数分 bin + 长期响度参考 + dB 映射）----
       flutter_soloud 给的是**线性幅度**，而且满量程素材（母带压到 0dB 的歌）
       峰值能到 1.0。旧实现按**每帧峰值**归一化 —— 每帧都必然有一个 bin
       顶到 1.0，整条曲线永远贴着天花板，动态范围全丢。

       现在改成「相对长期响度」的 dB 映射：
       - `_loudRef` 跟踪人声/音乐的整体电平（近似 LUFS 的短窗平均，
         起得慢落得更慢），把 0dBFS 素材整体"压低"后再看细节
       - `specLevel` 把幅度换成 dB，-40dB 以下压到 0、参考电平处为 1
       这样弱段有肉、强段也不会一路平顶。 */
    if (spectrumEnabled()) {
      // 显示频段 → FFT bin 的映射按 fft 长度缓存；换窗口/切歌才重算
      final fftLen = fft?.length ?? 0;
      if (fftLen > 0 && fftLen != _specBinN) {
        _specBins = buildSpecBins(fftLen);
        _specBinN = fftLen;
      }
      final mags = _magBuf;
      final bins = _specBins;

      // 长期响度参考：起快落慢（近似积分响度），只在真的有信号时更新
      if (real && playing) {
        final rms = _waveRms(wave);
        final coef = rms > _loudRef ? 0.10 : 0.012;
        _loudRef += (rms - _loudRef) * coef;
      }
      // 参考电平给个下限：极安静处不要把底噪放大成满屏
      final refLv = math.max(_loudRef, 0.02);
      final gain = _kSpecHeadroom / refLv;

      for (var i = 0; i < kSpecN; i++) {
        double m = 0;
        if (real && fft != null && bins != null) {
          m = fft[bins[i]].abs();
        } else if (playing && vol > 0) {
          final beat = math.pow(
              math.sin(tsec * math.pi * (128 / 60) + i * 0.6).abs(), 1.6);
          final wob = 0.5 + 0.5 * math.sin(tsec * 1.7 + i * 1.31);
          m = (0.12 + 0.88 * beat) * (0.35 + 0.65 * wob);
        }
        mags[i] = m;
      }

      for (var i = 0; i < kSpecN; i++) {
        final double t;
        if (real && fft != null) {
          t = specLevel(mags[i], gain);
        } else if (playing && vol > 0) {
          // BPM 模拟值本来就是 0..1 的幅度，不套 dB 映射
          t = math.min(1.0, math.pow(mags[i], 0.72) * 1.1).toDouble();
        } else {
          t = 0;
        }
        // 分频段平滑：低频（i 小）起落都慢，把能量拖住；
        // 高频跟手，抓瞬态。同一帧里两头的"手感"就是不一样。
        final k = t > specVals[i] ? _specAtk[i] : _specRel[i];
        specVals[i] += (t - specVals[i]) * k;
      }
      // 播放中才显示（无 FFT 时上游会给 BPM 模拟值，同样算「在播」）
      specLive = playing;
    } else {
      specLive = false;
    }

    /* ---- 声像：左右声道 → 宽度 → 颗粒场 ---- */
    if (imagerEnabled() && _canvasSize != Size.zero) {
      final stereo = engine is StereoEngine ? engine as StereoEngine : null;
      imager.update(
        stereo?.waveL,
        stereo?.waveR,
        active: real && playing,
      );
      // 封面半径要传进去：内圈地板必须在封面圆之外，
      // 否则点会藏到专辑图背后（曾经导致 drop 段整片看不见）
      imagerField.configure(
        _canvasSize,
        _coverRect?.center,
        coverRadius: (_coverRect?.shortestSide ?? 0) / 2,
      );
      imagerField.tick(dt, imager.width);
    } else {
      imager.update(null, null, active: false);
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
      pitchScale = 1;
      pitchGlow = 0;
      pitchBlur = 0;
      imager.update(null, null, active: false);
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
    // 先停再 dispose：Ticker 还在跑时直接销毁会在 debug 下断言，
    // 单元测试里 dispose 一个正在播放的 viz 就会炸。
    _ticker?.stop();
    _ticker?.dispose();
    _ticker = null;
    super.dispose();
  }
}
