/// 音高检测：从时域波形估基频，输出音符名（如 E5）。
///
/// 目标音色：高频 lead / guitar solo / pluck / color bass——
/// 瞬态快、响度高、基频集中在 180Hz–5kHz。
/// 三类干扰用不同门槛排掉：
///  - 镲片/齿音等「特别高频」：检测上限 2.5kHz
///  - 低响度的杂项音效：RMS 门槛（相对本段峰值，抗音量差异）
///  - 噪声般的非周期信号：归一化自相关置信度门槛
///
/// 算法：去直流 → YIN（累积均值归一化差值函数）→ 第一个明显谷
/// （=基频周期，谐波峰会被归一化抬平，不会像裸自相关那样跳到高次谐波）
/// → 抛物线插值到亚样本精度 → 频率 → MIDI → 音名。
///
/// 只在「两句歌词间隔 >10s」的窗口里跑（见 [longGapAt]），开销可忽略。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../models.dart';

/// 当前播放位置所处「长间隙」窗口：第 i 句到第 i+1 句，
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
    this.minHz = 180,
    this.maxHz = 5000,
    this.sampleRate = 44100,
    this.rmsFloor = 0.012,
    this.clarityMin = 0.55,
    this.stableFrames = 1,
    this.analysisSamples = 512,
  });

  /// 检测下限（低于此视为贝斯/底鼓，不算 lead）
  final double minHz;
  /// 检测上限。电子乐的 lead/pluck 可以很高（5kHz ≈ D#8），
  /// 镲片/齿音的排除交给过零率 sanity，而不是靠压上限。
  final double maxHz;
  final double sampleRate;
  /// 响度门槛（线性 RMS）：静音/弱音效直接跳过
  final double rmsFloor;
  /// 归一化自相关置信度门槛（0..1）
  final double clarityMin;
  /// 同一音高至少连续多少帧才算数。
  /// 1 = 只要一帧够响够清晰就锁定（要抓快速 lead/pluck 的瞬态）；
  /// 噪声由 RMS/置信度/过零率三道门负责挡。
  final int stableFrames;
  /// 参与分析的最新样本数（512 ≈ 11.6ms，短窗 = 快响应）
  final int analysisSamples;

  /// 本窗口锁定过的最高音（MIDI）
  int? bestMidi;
  /// 对应频率（Hz）
  double? bestHz;
  /// 音名（'E5'）
  String? get note => bestMidi == null ? null : midiNoteName(bestMidi!);
  /// 音名变化计数：驱动弹出动画
  int revision = 0;
  /// 最近一帧的置信度/响度（调试用）
  double lastClarity = 0, lastRms = 0;

  int? _runAnchor;
  int _run = 0;

  /// 每帧喂一次波形；返回本帧是否形成「稳定候选」。
  ///
  /// [wave] 为时域样本（-1..1）；[active] 为 false 时不做任何判断。
  bool update(Float32List? wave, {bool active = true}) {
    if (!active || wave == null || wave.length < 256) return false;

    final n = math.min(analysisSamples, wave.length);
    final start = wave.length - n; // 取最新的一段

    // 去直流
    var mean = 0.0;
    for (var i = start; i < wave.length; i++) {
      mean += wave[i];
    }
    mean /= n;

    final x = Float64List(n);
    var energy = 0.0;
    for (var i = 0; i < n; i++) {
      final v = wave[start + i] - mean;
      x[i] = v;
      energy += v * v;
    }
    final rms = math.sqrt(energy / n);
    lastRms = rms;
    if (rms < rmsFloor) {
      _run = 0;
      _runAnchor = null;
      lastClarity = 0;
      return false;
    }

    final minLag = (sampleRate / maxHz).floor().clamp(2, n ~/ 4);
    final maxLag = (sampleRate / minHz).ceil().clamp(minLag + 1, n ~/ 2);
    if (maxLag <= minLag) return false;

    // ---- YIN：差值函数 d(τ) + 累积均值归一化 d'(τ) ----
    // 为什么不用裸自相关：泛音丰富的音色（合成器 lead）在 T/2、T/3… 处
    // 都有很高的自相关峰，任何「取接近峰值的最早峰」的启发式都会跳到
    // 高次谐波上——实测低音被判成 C8（≈4186Hz，其实是它的高次谐波）。
    // YIN 的累积均值归一化会把真正的周期压成第一个深谷，谐波峰被抬平。
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

    // 第一个低于阈值的谷（再走到谷底）＝基频周期；这正是 YIN 抗谐波的关键
    const yinThreshold = 0.15;
    var bestLag = -1;
    for (var tau = minLag; tau <= maxLag; tau++) {
      if (cmnd[tau] < yinThreshold) {
        while (tau + 1 <= maxLag && cmnd[tau + 1] < cmnd[tau]) {
          tau++;
        }
        bestLag = tau;
        break;
      }
    }
    if (bestLag < 0) {
      // 没有明显谷（噪声/弱周期）：退回全局最小，并要求足够干净
      var m = double.infinity;
      for (var tau = minLag; tau <= maxLag; tau++) {
        if (cmnd[tau] < m) {
          m = cmnd[tau];
          bestLag = tau;
        }
      }
      lastClarity = 1 - (m.isFinite ? m : 1.0);
      if (bestLag < 0 || lastClarity < clarityMin) {
        _run = 0;
        _runAnchor = null;
        return false;
      }
    } else {
      lastClarity = 1 - cmnd[bestLag];
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

    final hz = sampleRate / lagF;
    if (hz < minHz || hz > maxHz) return false;

    // 过零率 sanity：镲片/齿音这类「特别高频」在低滞后处会混叠成
    // 一个假的低周期，但过零率仍远高于该周期对应值 —— 直接否掉。
    var zc = 0;
    for (var i = 1; i < n; i++) {
      if ((x[i - 1] < 0) != (x[i] < 0)) zc++;
    }
    final zcr = zc / (n / sampleRate); // 次/秒
    if (zcr > hz * 2 * 3.2) return false;

    final midi = (69 + 12 * (math.log(hz / 440) / math.ln2)).round();

    // 稳定帧计数（允许 ±1 半音的抖动/颤音）
    final anchor = _runAnchor;
    if (anchor != null && (midi - anchor).abs() <= 1) {
      _run++;
    } else {
      _runAnchor = midi;
      _run = 1;
    }
    if (_run < stableFrames) return false;

    // 只在更高的音出现时更新（本窗口取最高）
    final best = bestMidi;
    if (best == null || midi > best) {
      bestMidi = midi;
      bestHz = hz;
      revision++;
      return true;
    }
    return false;
  }

  /// 清空（离开长间隙 / 切歌 / 关特效）
  void reset() {
    bestMidi = null;
    bestHz = null;
    revision = 0;
    _run = 0;
    _runAnchor = null;
    lastClarity = 0;
    lastRms = 0;
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
