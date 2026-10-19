/// 音高检测：从时域波形估基频，输出音符名（如 E5）。
///
/// 两套截然不同的目标：
///  - [PitchTarget.vocal]     唱歌的人声：80–1100Hz，跟随当前音高（会随旋律变化）
///  - [PitchTarget.instrument]伴奏里的 lead / guitar solo / pluck / color bass：
///                            180–5kHz，音变了就换字（底部散落逐帧吐字）
///
/// 算法：去直流 → 抽取（人声降采样一半，省算力且窗口更长）→ 带限
/// （人声 90Hz–1.4kHz，乐器 260Hz 起、24dB/oct）→ YIN（差值函数 +
/// 累积均值归一化）→ 第一个深谷 = 基频周期 → 抛物线插值 → 频率 → MIDI → 音名。
///
/// 乐器档的核心是用户提的「**先分频，再检测对应频率的瞬态**」：
///  1. **陡峭分频**：四级一阶高通（≈24dB/oct）砍掉 instrumental 里的
///     底鼓与贝斯。两级只有 12dB/oct，55Hz 还剩 −24dB、110Hz 还剩 −14dB，
///     而它们本来就是混音里最响的成分 —— 能量上仍然压过 lead，
///     差值函数被低频主导，弱段的 lead 根本锁不上。
///  2. **多分辨率窗口**：低频要长窗、高频要短窗。固定 14.5ms 的窗口里
///     220Hz 只有 3 个周期，等于没有延拓可比；而 8kHz 用 46ms 窗口会
///     跨过好几次换音。检测在 [subdivideFrames] 个不同长度的子窗口里
///     从长到短依次尝试：长窗定案（八度最稳），长窗被换音搅浑才退短窗。
///  3. **段内自适应底**：绝对 RMS 门槛对整首曲子只有一把尺子，安静段
///     刚好卡在门槛上、副歌一响就全过 —— 用户听到的「歌词段反而更灵敏」
///     就是这个不对称。[relFloor] 让底随「最近的安静水平」浮动，只放宽、
///     绝不放紧；它**不是**「必须比常态响亮」的硬门槛（那样每帧都过不了）。
///
/// 两种场景的灵敏度是**分开调**的，不要合并：
///  - 乐器（lead / pluck / solo）：够快、够松 → 0.1s 级的瞬态也要抓住。
///  - 人声（歌词段）：更迟钝、更稳 → 只跟住真正唱稳的那个音
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../models.dart';

/// 声明的采样率：所有节点的系数都按它算，与波形实际采样率无关时
/// 只影响滤波器的精确截止频率，不影响稳定性。
const double kDetectorRate = 44100;

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
    this.sampleRate = kDetectorRate,
    this.decimate = 1,
    this.rmsFloor = 0.004,
    this.relFloor = kInstrumentRelFloor,
    this.clarityMin = 0.40,
    this.stableFrames = 1,
    this.analysisSamples = 1536,
    this.subdivideFrames = 3,
    this.yinThreshold = 0.26,
    this.highPassHz = 260,
    this.hpOrder = 4,
    this.lowPassHz = 0,
    this.takeHighest = true,
    this.holdFrames = 1,
  });

  /// 人声：窗口 23ms、跟随旋律、换音需稳住 4 帧（≈67ms）
  ///
  /// 灵敏度：比乐器档**稳**，但必须跟得上唱。曾经 holdFrames=6（≈100ms）
  /// 偏迟钝 —— 用户反馈「人声检测要更灵敏」，100ms 的滞后叠上检测窗口本身，
  /// 听感上字总是慢半拍。改 4 帧：仍能压掉单帧泛音跳八度、气声、辅音。
  /// clarityMin 也从 0.55 放到 0.46：真实人声混在伴奏里很难干净，门槛太高
  /// 会整句测不到 —— 那才是「迟钝」的主因，不是换音帧数。
  factory PitchDetector.vocal({
    double minHz = 85,
    double maxHz = 1100,
    double sampleRate = kDetectorRate,
    double rmsFloor = 0.0035,
    double clarityMin = 0.46,
    int analysisSamples = 512,
    double yinThreshold = 0.24,
    double highPassHz = 90,
    double lowPassHz = 1400,
    int holdFrames = 4,
  }) =>
      PitchDetector(
        target: PitchTarget.vocal,
        minHz: minHz,
        maxHz: maxHz,
        sampleRate: sampleRate,
        decimate: 2,
        rmsFloor: rmsFloor,
        relFloor: 0, // 人声不开相对门：只要唱得够响就该测到
        clarityMin: clarityMin,
        analysisSamples: analysisSamples,
        subdivideFrames: 1, // 人声是窄带、单音，不需要多分辨率
        yinThreshold: yinThreshold,
        highPassHz: highPassHz,
        hpOrder: 2,
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

  /// 绝对能量底（线性）：按**带限之前**的原始 RMS 判，低于它就当静音。
  /// 带限会把弱信号削掉一大截，拿带限后的值比这个底等于偷偷抬高门槛。
  final double rmsFloor;

  /// 段内自适应底（dB）：门槛随「最近的安静水平」下浮 `relFloor` dB。
  ///
  /// 只**放宽**，绝不放紧：`gate = min(rmsFloor, steady × 10^(−relFloor/20))`。
  /// 为什么需要它：绝对门槛对整首曲子只有一把尺子，安静段刚好卡在门槛上、
  /// 副歌一响就全过 —— 用户听到的「歌词段反而更灵敏、伴奏段不灵敏」
  /// 就是这个不对称。让它跟着段落下浮，安静的前奏/间奏里小一点的 lead
  /// 也能测到，副歌段由 [rmsFloor] 兜底。
  /// 0 = 关闭（人声档不开，人声只要够响就该测）。
  final double relFloor;

  /// 置信度门槛（1 - YIN 最小累积均值归一化差值）
  final double clarityMin;
  /// 同一音高至少连续多少帧才算数（2 帧 ≈ 33ms：守住 0.2s 级瞬态，
  /// 又不让单帧毛刺直接跳字）
  final int stableFrames;
  /// 抽取**之后**参与分析的样本数（最长那个子窗口）。
  /// 乐器 1536 ≈ 35ms（分 3 个子窗口 → 11.6/23/35ms），人声 512 ≈ 23ms
  int analysisSamples;
  /// 多分辨率：把分析的尾部切成几个递减长度的子窗口，各自跑一遍 YIN，
  /// 取置信度最高的那个。1 = 只用最长窗口（人声）。
  final int subdivideFrames;
  /// YIN 阈值下限（实际阈值 = max(本值, 全局最小 × 1.35)）
  final double yinThreshold;

  /// 带限：高通截止（0 = 关）。乐器 260Hz：底鼓主体与贝斯基频都在它下面，
  /// 但 220Hz（A3）的 lead 还留得住 —— 再抬就会削掉低音 lead。
  final double highPassHz;
  /// 高通阶数（一阶 = 6dB/oct）：乐器 4 级 ≈ 24dB/oct，人声 2 级 ≈ 12dB/oct。
  ///
  /// 级数要跟着 [highPassHz] 一起看：截止频率处每一级都掉 3dB，
  /// 截止频率**以下**才拉开差距。这就是「先分频」那一步。
  final int hpOrder;
  /// 带限：低通截止（0 = 关）。人声 1.4kHz，压掉镲片/齿音
  final double lowPassHz;

  /// true = 只保留窗口内最高的音（乐器）；false = 跟随当前音（人声）
  final bool takeHighest;
  /// 人声换音需要的连续帧数（压单帧毛刺/偶发八度跳）
  final int holdFrames;

  /// 每个子窗口的样本数（短 → 长）
  List<int>? _cachedLens;

  List<int> get _subLens {
    final cached = _cachedLens;
    if (cached != null) return cached;
    final k = subdivideFrames.clamp(1, 4);
    if (k <= 1) return _cachedLens = <int>[analysisSamples];
    final out = <int>[];

    for (var j = 0; j < k; j++) {
      final len = analysisSamples * (k - j) ~/ k;
      if (len >= 64 && !out.contains(len)) out.add(len);
    }
    // 统一升序：最后一个元素永远是**最长**的子窗口
    out.sort();
    return _cachedLens = out.isEmpty ? <int>[analysisSamples] : out;
  }
  /// 启动时观察到的波形长度：比 [analysisSamples] 短就按实际长度降级，
  /// 不然 YIN 的 `len - tau` 会变成负数（静默去掉整帧，等于永不触发）。
  void observeWaveLength(int waveSamples) {
    if (waveSamples <= 0) return;
    final maxLen = waveSamples ~/ decimate;
    if (maxLen >= analysisSamples) return;
    if (maxLen < 64) return;
    analysisSamples = maxLen;
    _cachedLens = null;
  }

  /// 子窗口因长度不足被裁掉时，外面要清一下已锁定的音
  int get activeSubframes => _subframes;
  int _subframes = 1;

  /// 最近一帧的「常态能量」（相对能量门的基准），线性 RMS
  double _steadyRms = 0;
  int _lowRmsFrames = 0;
  _Guess? _guess;

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
  /// 相对能量门的当前值（线性）：调试/测试可读
  double lastGate = 0;

  int? _runAnchor;
  int _run = 0;
  int? _pending;
  int _pendingRun = 0;

  /// 每帧喂一次波形；返回**显示音是否变化**（true 时驱动弹出动画）。
  ///
  /// [wave] 为时域样本（-1..1）；[active] 为 false 时不做任何判断。
  bool update(Float32List? wave, {bool active = true}) {
    lastValid = false;
    // 至少 64 个样本才可能有一次完整周期（高频端）
    if (!active || wave == null || wave.length < 64) return false;

    final fs = sampleRate / decimate;
    // 只保留「完整填满」的子窗口：波形比长窗短时，长窗会被截断成同一个长度，
    // 同一个 len 跑两遍既浪费又会让短窗结果覆盖长窗。
    final lens = [
      for (final l in _subLens)
        if (l * decimate <= wave.length) l,
    ];
    if (lens.isEmpty) return false;
    final maxLen = lens.last; // 升序：最后一个是长窗
    final take = maxLen * decimate;
    final n = take ~/ decimate;
    if (n < 64) return false;
    final start = wave.length - take; // 取最新的一段

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

    // ---- 带限（分频）：各目标只在自己关心的频段里评估 ----
    _highPass(x, highPassHz, fs, hpOrder);
    _lowPass(x, lowPassHz, fs);

    var bandEnergy = 0.0;
    for (final v in x) {
      bandEnergy += v * v;
    }
    lastBandRms = math.sqrt(bandEnergy / n);

    // ---- 相对能量：随段落自动调底，不需要「比常态高出多少」的硬门槛 ----
    //
    // 曾经这里写的是「本帧必须 ≥ 常态 × 10^(relFloor/20)」，那是错的：
    // 常态正好就是音乐本身的能量，任何一帧都不可能比自己所在段落的常态
    // 高出 8dB，于是整首曲子逐帧卡死、一个音都测不出来。这正是用户报的
    // 「无歌词段不灵敏」的机制。
    //
    // 正确的分工：
    //  - **绝对底**：[rmsFloor]，挡底噪（线性幅度，与段落无关）。
    //  - **相对底**：[relFloor] 相对「最近最安静时的能量」，让安静前奏/
    //    间奏里小一点的 lead 也能过；它只会比 rmsFloor 更低，不会更高。
    //  - **突出度**：不再做硬门槛。瞬态靠 [relFloor] 的段内自适应 + 多分辨率
    //    去抓，稳定度交给 [stableFrames]。
    final rms = lastBandRms;
    if (_steadyRms <= 0) {
      _steadyRms = rms;
    } else if (rms < _steadyRms) {
      // 跟随「最近的安静水平」：快降慢升（安静段一来就降下来）
      _steadyRms += (rms - _steadyRms) * 0.35;
    } else {
      _steadyRms += (rms - _steadyRms) * 0.02;
    }
    final relBase = relFloor > 0
        ? _steadyRms * math.pow(10, -relFloor / 20).toDouble()
        : rmsFloor;
    // 相对底只允许比绝对底更低（放宽），绝不允许更高（收紧）。
    // 反过来写就变成「常态 × 2.5」，任何声音都过不了。
    lastGate = math.min(rmsFloor, math.max(rmsFloor * 0.25, relBase));

    // 绝对底必须在**带限之后**判：带限会把弱信号削掉一大截，
    // 用带限后的 RMS 比 rmsFloor 等于把门槛偷偷抬高。
    if (lastRms < rmsFloor) {
      _fail();
      return false;
    }
    if (rms < lastGate) {
      // 允许连续两帧不达标（长音的能量低点、乐句呼吸），第三帧才丢
      if (++_lowRmsFrames >= 2) {
        _fail();
        return false;
      }
    } else {
      _lowRmsFrames = 0;
    }

    // 多分辨率：每个子窗口各跑一遍 YIN，取置信度最高的那个 ----
    // 最小滞后由 maxHz 决定。这里曾经写成 `.clamp(2, 4)`，把「下限 2」误
    // 打成了「上限 4」—— 人声档本该是 20（1100Hz），被压到 4（5.5kHz），
    // 于是高频噪声有机会冒充基频。
    final minLag = math.max(2, (fs / maxHz).floor());
    final maxLagAll = (fs / minHz).ceil();
    _guess = null;
    // 子窗口升序（短→长）。按实际长度决定能开几级（波形太短就退让）
    var maxK = lens.length;
    while (maxK > 1 && lens[maxK - 1] ~/ 2 <= minLag) {
      maxK--;
    }
    _subframes = math.max(1, math.min(maxK, n ~/ 64));

    // 从**最长**窗口往短里退：
    //  - 低频（周期长、τ 大）只有长窗才有足够的延拓可算；
    //  - 长窗一旦够可信就定案，八度错判最少；
    //  - 只有长窗跨过了换音（置信度不够）才退到短窗，去抓高频瞬态。
    // 反过来先看短窗会把 392Hz 判成 196Hz（短窗里低音更「整」，谷更深）。
    for (var k = _subframes - 1; k >= 0; k--) {
      final len = lens[k];
      // 短窗的 τ 上限压到 len−32：再长就几乎没项可比，d 会失真
      final lenSafe = math.min(len, n);
      // 取 min 而不是 clamp：len−32 可能比 maxLagAll 还小，
      // 一旦 clamp 到「比 minLag+1 还小」的区间，dart 的 clamp 会直接抛异常。
      final maxLag = math.min(maxLagAll, math.max(minLag + 2, lenSafe - 32));
      if (maxLag <= minLag) continue;
      final g = _yin(x, n - len, len, minLag, maxLag);
      if (g == null) continue;
      if (g.clarity < clarityMin) continue;
      _guess = g;
      break;
    }

    final g = _guess;
    if (g == null) {
      _fail();
      return false;
    }
    final hz = g.hzAt(fs);
    if (hz < minHz || hz > maxHz) {
      _fail();
      return false;
    }
    lastHz = hz;
    lastClarity = g.clarity;

    // 过零率 sanity：宽带高频噪声（镲片/齿音）会混叠成假基频，过零率对不上。
    // 6 倍上限是给「纯高频单音」留的路（它没有泛音，过零率约等于 2 倍频率）；
    // 真实音乐里真正的镲片/齿音能量比这高得多，靠置信度挡。
    final zcr = zcRaw / (n / fs);
    lastZcr = zcr;
    if (zcr > hz * 2 * 6.0) {
      _fail();
      return false;
    }

    final midi = (69 + 12 * (math.log(hz / 440) / math.ln2)).round();
    lastValid = true;

    /* ---- 乐器：音变了就更新（底部散落每变一个音就放一个） ----
     * 不再要求「必须更高」：散落字是逐帧吐字的，音从 G4 走回 G3 也是
     * 一个新的字，卡在「只接受更高」会让整段只吐出第一个音。
     * 仍然需要 [stableFrames] 帧稳住：单帧的泛音跳八度不进字。 */
    if (takeHighest) {
      final anchor = _runAnchor;
      if (anchor != null && (midi - anchor).abs() <= 1) {
        _run++;
      } else {
        _runAnchor = midi;
        _run = 1;
      }
      if (_run < stableFrames) return false;

      // 与原音名相同就不重复放，只刷新精确频率
      final best = bestMidi;
      if (best != null && best == midi) {
        bestHz = hz;
        return false;
      }
      bestMidi = midi;
      bestHz = hz;
      revision++;
      _run = 0; // 新字已放出，下一个字重新计数
      return true;
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

  /// 单次 YIN：在 `x[start, start+len)` 上算差值函数与累积均值归一化，
  /// 返回第一个够深的谷（抛物线插值后的周期 + 置信度）。不够可信返回 null。
  _Guess?   _yin(Float64List x, int start, int len, int minLag, int maxLag) {
    // 越界兜底：调用方的 `start` 若越过于 x 的尾部（早期把 wave 的偏移
    // 误当成 x 的偏移时就是这样），x[i+tau] 会读到 Float64List 之外。
    // 这里夹住区间，宁可窗口变短，也不让整帧静默失效。
    final maxStart = math.max(0, x.length - len);
    if (start > maxStart) start = maxStart;
    if (start < 0) start = 0;
    len = math.min(len, x.length - start);
    if (len < 64) return null;

    // 不用裸自相关：泛音丰富的音色在 T/2、T/3… 都有很高的自相关峰，
    // 任何「取接近峰值的最早峰」的启发式都会跳到高次谐波（实测低音被判成 C8）。
    //
    // maxLag 是**绝对上限**，不能跟着窗口长度缩：短窗若把 maxLag 压到 len/2，
    // 差值函数的求和只剩 len−tau 项，能量随 τ 递减，d(τ) 在窗口末端被压低，
    // 归一化后会被当成「周期 = 整个窗口」（实测 392Hz 短窗恒出 86Hz）。
    // 只有当剩余项数少于 32 时才停止（那时 d 已经不可信）。
    //
    // 关键：这里必须用**未归一化的求和** `Σ diff²`，不能写成 `sum / m`。
    // 差值函数随 τ 增长单调变大（能量随滞后累积），CMND 的 `d[τ]·τ / Σd`
    // 正好在这个趋势上做补偿，谷才是真的周期。若这里先除掉 m，等于给
    // 每个 τ 额外乘了一个 1/τ，CMND 就变成随 τ **单调递减**，最大值落在
    // 最长的滞后上 —— 一律被当成「周期 = 整个窗口」，人声档（maxLag 只到
    // 85Hz）因此恒判成低于下限，整帧丢弃。
    final d = Float64List(maxLag + 1);
    var limited = 0;
    for (var tau = 1; tau <= maxLag; tau++) {
      final m = len - tau;
      if (m < 32) {
        limited = tau;
        break;
      }
      var sum = 0.0;
      for (var i = 0; i < m; i++) {
        final diff = x[start + i] - x[start + i + tau];
        sum += diff * diff;
      }
      d[tau] = sum;
    }
    if (limited > 0) {
      // 不可信的尾部：复制最后一个可信值，让累积均值平推过去
      for (var tau = limited; tau <= maxLag; tau++) {
        d[tau] = d[limited - 1];
      }
    }
    final cmnd = Float64List(maxLag + 1);
    var running = 0.0;
    for (var tau = 1; tau <= maxLag; tau++) {
      running += d[tau];
      cmnd[tau] = running <= 1e-12 ? 1.0 : d[tau] * tau / running;
    }

    var minCmnd = double.infinity;
    for (var tau = minLag; tau <= maxLag; tau++) {
      if (cmnd[tau] < minCmnd) minCmnd = cmnd[tau];
    }
    if (!minCmnd.isFinite) return null;
    final clarity = (1 - minCmnd).clamp(0.0, 1.0);

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
      for (var tau = minLag; tau <= maxLag; tau++) {
        if (cmnd[tau] == minCmnd) {
          bestLag = tau;
          break;
        }
      }
    }
    if (bestLag < 0) return null;

    // 抛物线插值（谷底 → 亚样本精度）
    //
    // 过 (-1,c0) (0,c1) (1,c2) 的抛物线，顶点在
    //   t* = (c0 − c2) / [2·(c0 − 2c1 + c2)]
    // 分母这里一度写成 `2*(2c1 − c0 − c2)`，也就是标准分母取反 ——
    // 插值方向整个反了，频率系统性偏 0.5–3%（659Hz 被算成 639Hz，
    // 音名直接掉到 D#5）。这种偏差小到看着像「检测不准」，很难怀疑到
    // 插值上来，但它才是音名在边界处乱跳的根源。
    var lagF = bestLag.toDouble();
    if (bestLag > 1 && bestLag < maxLag) {
      final c0 = cmnd[bestLag - 1];
      final c1 = cmnd[bestLag];
      final c2 = cmnd[bestLag + 1];
      final denom = 2 * (c0 - 2 * c1 + c2);
      if (denom.abs() > 1e-12) {
        final delta = (c0 - c2) / denom;
        if (delta.abs() < 1) lagF += delta;
      }
    }
    if (lagF <= 0) return null;
    return _Guess(lagF, clarity);
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
    _steadyRms = 0;
    _lowRmsFrames = 0;
  }

  /// 一阶高通级联（每级 6dB/oct），就地处理。
  ///
  /// 级数就是「分频有多陡」：两级（12dB/oct）在截止频率以下掉得不够快，
  /// 贝斯基频（55–110Hz）仍有 −14…−24dB 的能量，仍是混音里最响的成分。
  static void _highPass(Float64List x, double fc, double fs, [int order = 2]) {
    if (fc <= 0 || x.isEmpty) return;
    final a = 1 / (1 + 2 * math.pi * fc / fs);
    for (var pass = 0; pass < math.max(1, order); pass++) {
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

/// 乐器档：段内自适应底（dB）。门槛随最近的安静水平下浮 8dB（≈2.5 倍），
/// 安静前奏/间奏里弱一点的 lead 也能测到；副歌段仍有 [rmsFloor] 兜底。
/// 只放宽、不放紧 —— 写成「必须比常态响亮 8dB」会让每一帧都过不了门。
const double kInstrumentRelFloor = 8;

/// 一次 YIN 的结果：周期（子样本精度，单位=抽取后的样本）+ 置信度
class _Guess {
  const _Guess(this.lag, this.clarity);
  final double lag;
  final double clarity;
  double hzAt(double fs) => fs / lag;
}

/// 逐帧决定「现在该检测人声还是乐器」。
///
/// 规则（用户要的行为）：
///  - **有歌词**：每句歌词开始 → 人声模式（封面中央字母）；出现下面两种情况
///    之一就切到乐器模式（底部散落），直到下一句开始：
///    1. 这句到下句的间隔 > [minGap]，且人声已经连续 [silenceSec] 秒测不到音
///       （间奏/纯乐器段）；
///    2. **这句自己就唱超过 [minGap] 秒**（超长句）：前 [minGap] 秒仍是人声，
///       之后转乐器 —— 用户对这种长句的期望是「>8s 的部分铺到背景上」。
///       长句里人声仍测得到音也照切，视觉上是「前 8s 中央字母，之后平铺」。
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
      // 超长句：本句自己已经唱了超过 minGap 秒 → 之后的部分改走散落。
      // 前 minGap 秒保持中央字母（熟悉的视觉），不要求人声静下来。
      final overdue = pos - lineStart > minGap;
      // 长间隙：两句间隔 > minGap，且人声已经静了 silenceSec
      final nextT = i + 1 < lines.length ? lines[i + 1].t : double.infinity;
      final longGapSilent = nextT - lineStart > minGap && _silence >= silenceSec;
      if (overdue || longGapSilent) {
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
