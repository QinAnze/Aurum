/// 音高检测：从时域波形估基频，输出音符名（如 E5）。
///
/// 两套截然不同的目标：
///  - [PitchTarget.vocal]     唱歌的人声：80–1100Hz，跟随当前音高（会随旋律变化）
///  - [PitchTarget.instrument]伴奏里的 lead / guitar solo / pluck / color bass：
///                            180–5kHz，取窗口内最高的那个音
///
/// 算法：去直流 → 抽取（人声降采样一半，省算力且窗口更长）→ 带限
/// （人声 90Hz–1.4kHz，乐器 150Hz 高通压掉贝斯/底鼓）→ YIN（差值函数 +
/// 累积均值归一化）→ 第一个深谷 = 基频周期 → 抛物线插值 → 频率 → MIDI → 音名。
///
/// 灵敏度靠三件事撑住（早期版本灵敏度低就是这三处太保守）：
///  1. YIN 阈值**自适应**：`max(下限, 全局最小 × 1.35)`，混音不干净时也能锁；
///  2. 带限后的 RMS 门槛（而不是整段混音的 RMS），弱一点的高音不会被贝斯掩蔽；
///  3. 人声/乐器各用各的窗口长度与稳定帧策略，不再用一套参数硬套两种场景。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../models.dart';

/// 检测目标：人声 or 乐器
enum PitchTarget { vocal, instrument }

/// 当前该跑哪种检测（由 [PitchWindow] 逐帧给出）
enum PitchPhase { off, vocal, instrument }

/// 当前播放位置所处的「长间隙」窗口：第 i 句到第 i+1 句，
/// 且两句间隔 > [minGap] 秒。不在这种位置返回 null。
({double start, double end, int index})? longGapAt(
  List<LyricLine> lines,
  double pos, {
  double minGap = 8,
}) {
  for (var i = 0; i < lines.length - 1; i++) {
    final a = lines[i].t;
    final b = lines[i + 1].t;
    if (b - a > minGap && pos >= a && pos < b) {
      return (start: a, end: b, index: i);
    }
  }
  return null;
}

const List<String> _kNoteNames = [
  'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B',
];

/// MIDI 编号 → 音名（60 → C4）
String midiNoteName(int midi) => '${_kNoteNames[midi % 12]}${midi ~/ 12 - 1}';

class PitchDetector {
  PitchDetector({
    this.target = PitchTarget.instrument,
    this.minHz = 180,
    this.maxHz = 5000,
    this.sampleRate = 44100,
    this.decimate = 1,
    this.rmsFloor = 0.004,
    this.clarityMin = 0.55,
    this.stableFrames = 2,
    this.analysisSamples = 640,
    this.yinThreshold = 0.20,
    this.highPassHz = 220,
    this.lowPassHz = 0,
    this.takeHighest = true,
    this.holdFrames = 1,
  });

  /// 人声：窗口 23ms、跟随旋律、换音需稳住 2 帧
  factory PitchDetector.vocal({
    double minHz = 85,
    double maxHz = 1100,
    double sampleRate = 44100,
    double rmsFloor = 0.005,
    double clarityMin = 0.55,
    int analysisSamples = 512,
    double yinThreshold = 0.22,
    double highPassHz = 90,
    double lowPassHz = 1400,
    int holdFrames = 3,
  }) =>
      PitchDetector(
        target: PitchTarget.vocal,
        minHz: minHz,
        maxHz: maxHz,
        sampleRate: sampleRate,
        decimate: 2,
        rmsFloor: rmsFloor,
        clarityMin: clarityMin,
        analysisSamples: analysisSamples,
        yinThreshold: yinThreshold,
        highPassHz: highPassHz,
        lowPassHz: lowPassHz,
        takeHighest: false,
        holdFrames: holdFrames,
      );

  final PitchTarget target;

  /// 检测下限（人声 85Hz ≈ F2；乐器 180Hz 以下算贝斯/底鼓）
  final double minHz;
  /// 检测上限（电子乐 lead 可以很高，5kHz ≈ D#8）
  final double maxHz;
  final double sampleRate;
  /// 抽取倍数：2 = 降采样一半（人声用，窗口更长、算力更省）
  final int decimate;

  /// 带限后的 RMS 门槛（线性）：静音/弱到测不准的帧直接跳过
  final double rmsFloor;
  /// 置信度门槛（1 - YIN 最小累积均值归一化差值）
  final double clarityMin;
  /// 同一音高至少连续多少帧才算数（2 帧 ≈ 33ms：守住 0.2s 级瞬态，
  /// 又不让单帧毛刺直接跳字）
  final int stableFrames;
  /// 抽取**之后**参与分析的样本数（人声 512 ≈ 23ms；乐器 640 ≈ 14.5ms）
  final int analysisSamples;
  /// YIN 阈值下限（实际阈值 = max(本值, 全局最小 × 1.35)）
  final double yinThreshold;

  /// 带限：高通截止（0 = 关）。乐器默认 220Hz（两级 ≈ 12dB/oct）：
  /// 55Hz 的贝斯被压约 -24dB、110Hz 约 -12dB，而 220Hz 以上几乎不动。
  /// 不这么做的话，混音里最响的贝斯会让 YIN 锁到贝斯而不是 lead。
  final double highPassHz;
  /// 带限：低通截止（0 = 关）。人声 1.4kHz，压掉镲片/齿音
  final double lowPassHz;

  /// true = 只保留窗口内最高的音（乐器）；false = 跟随当前音（人声）
  final bool takeHighest;
  /// 人声换音需要的连续帧数（压单帧毛刺/偶发八度跳）
  final int holdFrames;

  /// 当前显示的音（MIDI / Hz）
  int? bestMidi;
  double? bestHz;
  /// 音名（'E5'）
  String? get note => bestMidi == null ? null : midiNoteName(bestMidi!);
  /// 音名变化计数：驱动弹出动画
  int revision = 0;
  /// 本帧是否测到一个可信音高（供 [PitchWindow] 判断「还在唱」）
  bool lastValid = false;
  /// 最近一帧的置信度/响度（调试用）
  double lastClarity = 0, lastRms = 0, lastBandRms = 0;
  /// 最近一帧原始判定的频率 / 过零率（调试用）
  double lastHz = 0, lastZcr = 0;

  int? _runAnchor;
  int _run = 0;
  int? _pending;
  int _pendingRun = 0;

  /// 每帧喂一次波形；返回**显示音是否变化**（true 时驱动弹出动画）。
  ///
  /// [wave] 为时域样本（-1..1）；[active] 为 false 时不做任何判断。
  bool update(Float32List? wave, {bool active = true}) {
    lastValid = false;
    if (!active || wave == null || wave.length < 256) return false;

    final need = analysisSamples * decimate;
    final take = math.min(wave.length, need);
    final start = wave.length - take; // 取最新的一段
    final n = take ~/ decimate;
    if (n < 128) return false;

    // 去直流 + 抽取（抽取前两点平均，粗糙抗混叠；后面还有低通兜着）
    var mean = 0.0;
    for (var i = 0; i < take; i++) {
      mean += wave[start + i];
    }
    mean /= take;

    final x = Float64List(n);
    var rawEnergy = 0.0;
    for (var i = 0; i < n; i++) {
      final a = wave[start + i * decimate] - mean;
      final v = decimate == 1
          ? a
          : 0.5 * (a + (wave[start + i * decimate + decimate - 1] - mean));
      x[i] = v;
      rawEnergy += v * v;
    }
    lastRms = math.sqrt(rawEnergy / n);

    // 过零率在**带限之前**统计：高通会把波形削尖、过零数翻几倍，
    // 拿滤波后的信号判会把正常音色误杀（实测 A3 被算成 1998 次/秒）。
    var zcRaw = 0;
    for (var i = 1; i < n; i++) {
      if ((x[i - 1] < 0) != (x[i] < 0)) zcRaw++;
    }

    final fs = sampleRate / decimate;

    // 带限：各目标只在自己关心的频段里评估
    _highPass(x, highPassHz, fs);
    _lowPass(x, lowPassHz, fs);

    var bandEnergy = 0.0;
    for (final v in x) {
      bandEnergy += v * v;
    }
    lastBandRms = math.sqrt(bandEnergy / n);
    if (lastBandRms < rmsFloor) {
      _fail();
      return false;
    }

    final minLag = (fs / maxHz).floor().clamp(2, n ~/ 4);
    final maxLag = (fs / minHz).ceil().clamp(minLag + 1, n ~/ 2);
    if (maxLag <= minLag) return false;

    // ---- YIN：差值函数 d(τ) + 累积均值归一化 d'(τ) ----
    // 不用裸自相关：泛音丰富的音色在 T/2、T/3… 都有很高的自相关峰，
    // 任何「取接近峰值的最早峰」的启发式都会跳到高次谐波（实测低音被判成 C8）。
    final d = Float64List(maxLag + 1);
    for (var tau = 1; tau <= maxLag; tau++) {
      var sum = 0.0;
      final m = n - tau;
      for (var i = 0; i < m; i++) {
        final diff = x[i] - x[i + tau];
        sum += diff * diff;
      }
      d[tau] = sum;
    }
    final cmnd = Float64List(maxLag + 1);
    var running = 0.0;
    for (var tau = 1; tau <= maxLag; tau++) {
      running += d[tau];
      cmnd[tau] = running <= 1e-12 ? 1.0 : d[tau] * tau / running;
    }

    // 全局最小（置信度用）
    var minCmnd = double.infinity;
    for (var tau = minLag; tau <= maxLag; tau++) {
      if (cmnd[tau] < minCmnd) minCmnd = cmnd[tau];
    }
    lastClarity = minCmnd.isFinite ? (1 - minCmnd).clamp(0.0, 1.0) : 0.0;

    // 自适应阈值：混音里 YIN 的谷不会那么深，固定 0.15 会漏掉大半个音
    // （旧版要求 cmnd < 0.15 ≈ 置信度 > 0.85，真实音乐几乎不可能满足）。
    // accept 只收「接近全局最深」的谷，避免小滞后处的浅谷被当成基频。
    final thr = math.max(yinThreshold, minCmnd * 1.35).clamp(0.0, 0.6);
    final accept = math.min(thr, minCmnd * 1.6);

    var bestLag = -1;
    for (var tau = minLag; tau <= maxLag; tau++) {
      if (cmnd[tau] > accept) continue;
      // 走到这个谷的谷底：取第一个「够深」的谷才不会掉到 2T（低八度）
      var t = tau;
      while (t + 1 <= maxLag && cmnd[t + 1] < cmnd[t]) {
        t++;
      }
      bestLag = t;
      break;
    }
    if (bestLag < 0) {
      // 没有够深的谷：退回全局最小
      for (var tau = minLag; tau <= maxLag; tau++) {
        if (cmnd[tau] == minCmnd) {
          bestLag = tau;
          break;
        }
      }
    }
    if (bestLag < 0 || lastClarity < clarityMin) {
      _fail();
      return false;
    }

    // 抛物线插值（谷底 → 亚样本精度）
    var lagF = bestLag.toDouble();
    if (bestLag > 1 && bestLag < maxLag) {
      final c0 = cmnd[bestLag - 1];
      final c1 = cmnd[bestLag];
      final c2 = cmnd[bestLag + 1];
      final denom = 2 * (2 * c1 - c0 - c2);
      if (denom.abs() > 1e-12) {
        final delta = (c0 - c2) / denom;
        if (delta.abs() < 1) lagF += delta;
      }
    }
    if (lagF <= 0) return false;

    final hz = fs / lagF;
    lastHz = hz;
    if (hz < minHz || hz > maxHz) {
      _fail();
      return false;
    }

    // 过零率 sanity：宽带高频噪声（镲片/齿音）会混叠成假基频，过零率对不上
    final zcr = zcRaw / (n / fs);
    lastZcr = zcr;
    if (zcr > hz * 2 * 6.0) {
      _fail();
      return false;
    }

    final midi = (69 + 12 * (math.log(hz / 440) / math.ln2)).round();
    lastValid = true;

    /* ---- 乐器：只在更高的音出现时更新（窗口内取最高） ---- */
    if (takeHighest) {
      final anchor = _runAnchor;
      if (anchor != null && (midi - anchor).abs() <= 1) {
        _run++;
      } else {
        _runAnchor = midi;
        _run = 1;
      }
      if (_run < stableFrames) return false;

      final best = bestMidi;
      if (best == null || midi > best) {
        bestMidi = midi;
        bestHz = hz;
        revision++;
        return true;
      }
      return false;
    }

    /* ---- 人声：跟随当前音，换音需连续 holdFrames 帧 ---- */
    final held = bestMidi;
    if (held == null) {
      bestMidi = midi;
      bestHz = hz;
      revision++;
      _pending = midi;
      _pendingRun = 0;
      return true;
    }
    if (midi == held) {
      bestHz = hz; // 同音：刷新精确频率，不重放动画
      _pending = midi;
      _pendingRun = 0;
      return false;
    }
    if (_pending != null && (midi - _pending!).abs() <= 1) {
      _pendingRun++;
    } else {
      _pending = midi;
      _pendingRun = 1;
    }
    if (_pendingRun >= holdFrames) {
      bestMidi = midi;
      bestHz = hz;
      revision++;
      _pending = midi;
      _pendingRun = 0;
      return true;
    }
    return false;
  }

  void _fail() {
    _run = 0;
    _runAnchor = null;
    _pendingRun = 0;
  }

  /// 清空（离开窗口 / 切歌 / 关特效）
  void reset() {
    bestMidi = null;
    bestHz = null;
    revision = 0;
    _run = 0;
    _runAnchor = null;
    _pending = null;
    _pendingRun = 0;
    lastValid = false;
    lastClarity = 0;
    lastRms = 0;
    lastBandRms = 0;
  }

  /// 两级一阶高通（≈12dB/oct），就地处理
  static void _highPass(Float64List x, double fc, double fs) {
    if (fc <= 0 || x.isEmpty) return;
    final a = 1 / (1 + 2 * math.pi * fc / fs);
    for (var pass = 0; pass < 2; pass++) {
      var prevIn = x[0];
      var prevOut = 0.0;
      for (var i = 0; i < x.length; i++) {
        final v = x[i];
        prevOut = a * (prevOut + v - prevIn);
        prevIn = v;
        x[i] = prevOut;
      }
    }
  }

  /// 两级一阶低通（≈12dB/oct），就地处理
  static void _lowPass(Float64List x, double fc, double fs) {
    if (fc <= 0 || x.isEmpty) return;
    final c = 1 - math.exp(-2 * math.pi * fc / fs);
    for (var pass = 0; pass < 2; pass++) {
      var y = 0.0;
      for (var i = 0; i < x.length; i++) {
        y += c * (x[i] - y);
        x[i] = y;
      }
    }
  }
}

/// 逐帧决定「现在该检测人声还是乐器」。
///
/// 规则（用户要的行为）：
///  - **有歌词**：每句歌词开始 → 人声模式；若这句到下句的间隔 > [minGap]，
///    且人声已经连续 [silenceSec] 秒测不到音（间奏/纯乐器段），
///    切到乐器模式，直到下一句开始。
///  - **无歌词**（或不足两句）：只按「持续响度最大段」（一般是 drop）
///    走乐器模式。
///  - 第一句歌词之前（前奏）按无歌词处理。
class PitchWindow {
  PitchWindow({this.minGap = 8, this.silenceSec = 1.2});

  /// 长间隙阈值（秒）：两句歌词间隔超过它才可能是纯乐器段
  final double minGap;
  /// 人声连续测不到多久就认为「唱完了」，切乐器。
  /// 1.2s：字母在 0.6s 时先落下（界面门限），0.38s 落完，
  /// 1.2s 切到乐器段再从底部升起来——落和升之间留一个呼吸。
  final double silenceSec;

  PitchPhase phase = PitchPhase.off;

  /// 人声已经连续多久没测到音（秒）：界面上用它决定字母什么时候收掉
  double get silence => _silence;

  double? _anchor;
  double _silence = 0;

  /// 每帧调用一次，返回本帧应使用的相位。
  ///
  /// [vocalHeard] 为本帧人声检测是否测到可信音高（仅在人声相位有意义）。
  PitchPhase update({
    required List<LyricLine> lines,
    required double pos,
    required double dt,
    required bool playing,
    required bool vocalHeard,
    required bool loudActive,
  }) {
    // 无歌词 / 不足两句：靠响度段
    if (lines.length < 2) {
      _anchor = null;
      _silence = 0;
      phase = loudActive ? PitchPhase.instrument : PitchPhase.off;
      return phase;
    }

    final i = _lineIndexAt(lines, pos);
    if (i < 0) {
      // 第一句之前（前奏）：按响度段判
      _anchor = null;
      _silence = 0;
      phase = loudActive ? PitchPhase.instrument : PitchPhase.off;
      return phase;
    }

    final lineStart = lines[i].t;
    if (_anchor != lineStart) {
      // 新的一句：回到人声相位
      _anchor = lineStart;
      _silence = 0;
      phase = PitchPhase.vocal;
    }

    if (phase == PitchPhase.vocal) {
      if (playing) {
        _silence = vocalHeard ? 0 : _silence + dt;
      }
      final nextT = i + 1 < lines.length ? lines[i + 1].t : double.infinity;
      final hasGap = nextT - lineStart > minGap;
      if (hasGap && _silence >= silenceSec) {
        phase = PitchPhase.instrument;
      }
    }
    return phase;
  }

  void reset() {
    phase = PitchPhase.off;
    _anchor = null;
    _silence = 0;
  }

  static int _lineIndexAt(List<LyricLine> lines, double pos) {
    var lo = 0, hi = lines.length - 1, ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].t <= pos + 0.05) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }
}

/// 无歌词曲目的「持续响度最大段」跟踪器（通常就是 drop）。
///
/// 直播流看不到未来，只能按「到目前为止最响的那一档」近似：
///  - 0.25s 平滑 RMS
///  - 峰值保持 + 极慢回落（半衰期约 2 分钟）
///  - 高于「峰值 × gateRatio」并持续 [attackSec] → 进入响段
///  - 低于门槛持续 [releaseSec] → 退出响段
///  - 开头 [warmupSec] 秒不触发（等峰值立起来，避免 intro 就亮）
class LoudSectionTracker {
  LoudSectionTracker({
    this.attackSec = 0.8,
    this.releaseSec = 2.5,
    this.gateRatio = 0.55,
    this.floor = 0.008,
    this.smoothTau = 0.25,
    this.warmupSec = 4,
  });

  /// 持续多响才进入响段（秒）
  final double attackSec;
  /// 低于门槛多久退出（秒）
  final double releaseSec;
  /// 相对峰值的门槛比例
  final double gateRatio;
  /// 绝对底噪门（安静曲子也要求有一点能量）
  final double floor;
  final double smoothTau;
  final double warmupSec;

  bool get active => _active;
  double get rms => _rms;
  double get peak => _peak;

  bool _active = false;
  double _rms = 0;
  double _peak = 0;
  double _loudRun = 0;
  double _quietRun = 0;
  double _t = 0;

  void update(double rawRms, double dt) {
    dt = dt.clamp(0.0, 0.1);
    _t += dt;

    final k = 1 - math.exp(-dt / smoothTau);
    _rms += (rawRms - _rms) * k;
    _peak = math.max(_rms, _peak * math.exp(-dt / 120.0));

    final gate = math.max(_peak * gateRatio, floor);
    if (_rms > gate) {
      _loudRun += dt;
      _quietRun = 0;
    } else {
      _quietRun += dt;
      if (_quietRun > 0.4) _loudRun = 0;
    }

    if (!_active && _t >= warmupSec && _loudRun >= attackSec) _active = true;
    if (_active && _quietRun >= releaseSec) _active = false;
  }

  void reset() {
    _active = false;
    _rms = 0;
    _peak = 0;
    _loudRun = 0;
    _quietRun = 0;
    _t = 0;
  }
}
