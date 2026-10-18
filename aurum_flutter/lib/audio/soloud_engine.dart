/// Aurum · flutter_soloud 播放引擎（PlayerEngine 契约的桌面端实现）。
/// 对应原版 HTMLAudioElement + Web Audio 的行为：
///  - 候选播放地址链逐级试错（error=换下一个，canplay=成功）
///  - play/pause/seek/volume/静音
///  - 实时 FFT + 时域波形（setVisualizationEnabled → audioVisualizationEvents）
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:http/http.dart' as http;

import 'audio_probe.dart';
import 'load_gate.dart';
import 'player_engine.dart';

const String _kUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

class SoloudEngine implements PlayerEngine {
  SoloudEngine();

  final SoLoud _soloud = SoLoud.instance;
  final StreamController<EngineEvent> _events =
      StreamController<EngineEvent>.broadcast();
  final http.Client _client = http.Client();

  Future<void>? _initFuture;
  StreamSubscription<AudioVisualizationData>? _visSub;
  StreamSubscription<StreamSoundEvent>? _soundSub;
  Timer? _posTimer;

  AudioSource? _source;
  SoundHandle? _handle;
  /// 本会话创建过的全部 voice / source（切歌时统一回收，防止泄漏叠播）
  final List<SoundHandle> _voices = [];
  final List<AudioSource> _sources = [];
  bool _handleAlive = false;
  bool _playing = false;
  double _durationSec = 0;
  double _volume = 1.0;
  double _pendingSeek = -1;
  int _loadCounter = 0;
  /// 切歌代号门闩：只有最新一次 loadAndPlay 允许落地（防并发交叉导致叠播）
  final LoadGate _gate = LoadGate();

  Float32List? _fft;
  Float32List? _wave;

  @override
  Stream<EngineEvent> get events => _events.stream;

  @override
  Float32List? get fft => _fft;

  @override
  Float32List? get wave => _wave;

  /* ---------------- 初始化 ---------------- */

  Future<void> _doInit() async {
    await _soloud.init();
    // 可视化：与原版 AnalyserNode(fftSize 2048) 对齐 → fft 1024 bins / wave 2048 samples
    _soloud.setVisualizationEnabled(
      true,
      windowSize: 2048,
      kind: VisualizationKind.waveAndFft,
      channel: VisualizationChannel.merged,
    );
    _soloud.setFftSmoothing(0.78); // 对应原版 smoothingTimeConstant
    _visSub = _soloud.audioVisualizationEvents.listen((data) {
      _fft = data.fftData;
      _wave = data.waveData;
    });
  }

  @override
  Future<void> init() {
    _initFuture ??= _doInit();
    return _initFuture!;
  }

  /* ---------------- 下载 + 加载 + 播放 ---------------- */

  Future<Uint8List?> _download(String url) async {
    // 本地文件：直接读字节，不走 HTTP（file:// 或裸绝对路径）
    final path = _localPathOf(url);
    if (path != null) {
      try {
        final f = File(path);
        if (!await f.exists()) return null;
        return await f.readAsBytes();
      } catch (_) {
        return null;
      }
    }
    final r = await _client
        .get(Uri.parse(url), headers: {'User-Agent': _kUa})
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) return null;
    return r.bodyBytes;
  }

  /// 若是本地文件地址，返回可直接打开的路径；否则 null。
  ///
  /// 支持 `file:///C:/x/y.mp3`（Uri 解码后）、`file://`，以及 Windows 裸路径
  /// `C:\x\y.mp3` / `\\server\share\a.mp3`。
  String? _localPathOf(String url) {
    if (url.isEmpty) return null;
    if (url.length >= 4 &&
        RegExp(r'^[a-zA-Z]:[\\/]').matchAsPrefix(url) != null) {
      return url; // 裸 Windows 盘符路径
    }
    if (url.startsWith(r'\\')) return url; // UNC
    if (url.startsWith('file:')) {
      try {
        return Uri.parse(url).toFilePath();
      } catch (_) {
        return null;
      }
    }
    if (url.startsWith('/')) return url; // POSIX 绝对路径
    return null;
  }

  @override
  Future<bool> loadAndPlay(List<String> urls) async {
    // 代号机制：每次切歌 +1。下载/加载过程中若被更新的请求抢占，
    // 本次立即放弃并把自己刚建的音源销毁——否则「A 下载未完 → 切 B →
    // B 清场已完成 → A 才 play」会让两首歌一起响。
    final gen = _gate.begin();
    await init();

    // 串行化：等上一轮加载收尾，避免清场与加载交叉
    if (!await _gate.acquire(gen)) return false;
    try {
      await _stopInternal();

      for (final url in urls) {
        if (!_gate.isCurrent(gen)) return false;
        try {
          final bytes = await _download(url);
          if (!_gate.isCurrent(gen)) return false; // 下载期间被抢占，直接放弃
          if (bytes == null || bytes.length < 1024) {
            _events.add(EngineLoadFailed());
            continue;
          }
          final dur = probeAudioDuration(bytes);
          final path = 'aurum://track-${++_loadCounter}';
          final sound = await _soloud.loadMem(
            path,
            bytes,
            mode: LoadMode.memory,
            autoDispose: false,
          );
          // 加载完成后、play 之前再确认一次：被抢占就销毁，绝不落地
          if (!_gate.isCurrent(gen)) {
            try {
              await _soloud.disposeSource(sound);
            } catch (_) {}
            return false;
          }
          _durationSec = dur ?? 0;
          final handle = _soloud.play(sound, volume: _volume);
          if (handle.isError) {
            _events.add(EngineLoadFailed());
            try {
              await _soloud.disposeSource(sound);
            } catch (_) {}
            continue;
          }
          // play 之后最后一次确认：若已被抢占，立刻把自己停掉并销毁
          if (!_gate.isCurrent(gen)) {
            try {
              _soloud.setPause(handle, false);
              await _soloud.stop(handle).timeout(const Duration(seconds: 1));
            } catch (_) {}
            try {
              await _soloud.disposeSource(sound);
            } catch (_) {}
            return false;
          }
          _source = sound;
          _sources.add(sound);
          _handle = handle;
          _voices.add(handle);
          _handleAlive = true;
          _playing = true;
          _listenSource(sound, handle);
          if (_pendingSeek >= 0) {
            _soloud.seek(
                handle, Duration(milliseconds: (_pendingSeek * 1000).round()));
            _pendingSeek = -1;
          }
          _startPosTimer();
          _events.add(EngineDurationChanged(_durationSec));
          _events.add(EnginePlayingChanged(true));
          return true;
        } catch (_) {
          _events.add(EngineLoadFailed());
        }
      }
      _events.add(EngineAllCandidatesFailed());
      return false;
    } finally {
      _gate.release();
    }
  }

  void _listenSource(AudioSource sound, SoundHandle handle) {
    _soundSub?.cancel();
    _soundSub = sound.soundEvents.listen((e) {
      if (e.event == SoundEventType.handleIsNoMoreValid &&
          e.handle.id == handle.id) {
        _handleAlive = false;
        _playing = false;
        _posTimer?.cancel();
        _voices.removeWhere((h) => h.id == handle.id);
        _events.add(EngineEnded());
      }
    });
  }

  /* ---------------- 播放控制 ---------------- */

  @override
  bool get hasSource => _source != null;

  @override
  bool get isPlaying => _playing && _handleAlive;

  @override
  double get positionSec {
    if (!_handleAlive || _handle == null) return 0;
    try {
      return _soloud.getPosition(_handle!).inMilliseconds / 1000.0;
    } catch (_) {
      return 0;
    }
  }

  @override
  double get durationSec => _durationSec;

  @override
  Future<void> play() async {
    await init();
    if (_source == null) return;
    // 当前 voice 已结束（如单曲循环重播）：同源重开一个 voice，等价于 Web 的
    // audio.currentTime=0; audio.play()
    if (!_handleAlive || _handle == null) {
      final handle = _soloud.play(_source!, volume: _volume);
      if (handle.isError) return;
      _handle = handle;
      _voices.add(handle);
      _handleAlive = true;
      _listenSource(_source!, handle);
      if (_pendingSeek >= 0) {
        _soloud.seek(
            handle, Duration(milliseconds: (_pendingSeek * 1000).round()));
        _pendingSeek = -1;
      }
    } else {
      _soloud.setPause(_handle!, false);
    }
    _playing = true;
    _startPosTimer();
    _events.add(EnginePlayingChanged(true));
  }

  @override
  Future<void> pause() async {
    if (!_handleAlive || _handle == null) return;
    try {
      _soloud.setPause(_handle!, true);
    } catch (_) {
      return;
    }
    _playing = false;
    _posTimer?.cancel();
    _events.add(EnginePlayingChanged(false));
  }

  @override
  Future<void> seek(double sec) async {
    if (sec < 0) sec = 0;
    if (_durationSec > 0 && sec > _durationSec) sec = _durationSec;
    if (!_handleAlive || _handle == null) {
      _pendingSeek = sec; // voice 未就绪：记下，下次 play 时应用
      return;
    }
    try {
      _soloud.seek(_handle!, Duration(milliseconds: (sec * 1000).round()));
    } catch (_) {}
    _events.add(EnginePositionChanged(sec));
  }

  /* ---------------- 音量 ---------------- */

  @override
  double get volume => _volume;

  @override
  Future<void> setVolume(double v) async {
    _volume = v.clamp(0.0, 1.0);
    if (_handleAlive && _handle != null) {
      try {
        _soloud.setVolume(_handle!, _volume);
      } catch (_) {}
    }
  }

  /* ---------------- 位置轮询 ---------------- */

  void _startPosTimer() {
    _posTimer?.cancel();
    _posTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!_playing || !_handleAlive || _handle == null) return;
      try {
        _events.add(
            EnginePositionChanged(_soloud.getPosition(_handle!).inMilliseconds / 1000.0));
      } catch (_) {}
    });
  }

  /* ---------------- 清理 ---------------- */

  Future<void> _stopInternal() async {
    _posTimer?.cancel();
    _posTimer = null;
    // 关键：先断开旧音源的事件订阅，再清场。
    // flutter_soloud 对 stop()/disposeSource() 也会发 handleIsNoMoreValid
    // （插件文档：Every stopped voice emits a handleIsNoMoreValid event），
    // 那是「我们主动停掉」的回声；若被 _listenSource 收到会当成自然播完，
    // 触发 AppState.next() —— 表现为「点第 i 首却放第 i+1 首」。
    _soundSub?.cancel();
    _soundSub = null;
    // 把「本会话创建过的所有 voice / source」都收走。
    // 只停 _handle 的话，一旦某次 stop 异常/超时，句柄就被丢掉、
    // 旧歌永远停不下来（切歌后两首叠着放）。
    final handles = List<SoundHandle>.from(_voices);
    final sources = List<AudioSource>.from(_sources);
    _voices.clear();
    _sources.clear();
    _handle = null;
    _handleAlive = false;
    _playing = false;

    for (final h in handles) {
      try {
        // 先唤醒：暂停态的 voice 拿不到原生 voiceEnded 回调，stop() 会一直等。
        // 这里是毫秒级操作，听不出来，但能显著提高 stop 正常返回的概率。
        _soloud.setPause(h, false);
      } catch (_) {}
      try {
        // stop() 要等原生 voiceEnded 回调才完成；设备空闲/异常时该回调可能不来，
        // 必须加超时，否则整条「切歌 → 加载新歌」的链会被卡死。
        await _soloud.stop(h).timeout(const Duration(seconds: 2));
      } catch (_) {
        // 超时或已失效：交给下面的 disposeSource 兜底
      }
    }
    for (final s in sources) {
      try {
        await _soloud
            .disposeSource(s)
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    // 兜底：引擎里残留的其它音源（含历史泄漏的 voice）统统丢掉。
    // 此刻新音源尚未加载，清场是安全的。
    try {
      for (final s in List<AudioSource>.from(_soloud.activeSounds)) {
        await _soloud
            .disposeSource(s)
            .timeout(const Duration(seconds: 2));
      }
    } catch (_) {}
    _source = null;
  }

  @override
  void dispose() {
    _posTimer?.cancel();
    _soundSub?.cancel();
    _visSub?.cancel();
    _events.close();
    _client.close();
    _soloud.deinit();
  }
}
