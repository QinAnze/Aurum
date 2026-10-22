/// 播放引擎抽象契约。
/// Web 版基于 HTMLAudioElement + Web Audio AnalyserNode；
/// 桌面版由 audio/soloud_engine.dart 用 flutter_soloud 实现。
/// 契约层：widgets/effects 不 import 具体实现，只经 AppState 访问。
library;

import 'dart:typed_data';

/// 引擎向 AppState 推送的事件
sealed class EngineEvent {}

class EnginePlayingChanged extends EngineEvent {
  EnginePlayingChanged(this.playing);
  final bool playing;
}

class EnginePositionChanged extends EngineEvent {
  EnginePositionChanged(this.positionSec);
  final double positionSec;
}

class EngineDurationChanged extends EngineEvent {
  EngineDurationChanged(this.durationSec);
  final double durationSec;
}

/// 自然播完（对应原版 audio.ended）
class EngineEnded extends EngineEvent {}

/// 当前候选 URL 播放失败（对应原版 audio.error，候选链内由引擎换下一个）
class EngineLoadFailed extends EngineEvent {}

/// 全部候选失败（对应原版 tryPlayUrls resolve(false)）
class EngineAllCandidatesFailed extends EngineEvent {}

/// 可选能力：能给出**分声道**波形（声像/立体声宽度检测用）。
///
/// 单独一个接口而不是塞进 [PlayerEngine]，是因为所有测试替身都在
/// `implements PlayerEngine` —— 往里加成员会让一堆 stub 编译失败。
/// 引擎不实现它时，声像按「单声道」处理，特效自然停在最小状态。
abstract class StereoEngine {
  /// 左声道时域波形（-1..1）
  Float32List? get waveL;
  /// 右声道时域波形（-1..1）
  Float32List? get waveR;
}

abstract class PlayerEngine {
  /// 初始化（幂等）
  Future<void> init();

  /// 依次尝试候选播放地址：某条 canplay 即成功播放，全部失败返回 false
  /// （对应原版 tryPlayUrls：error=换下一个，canplay=成功）
  Future<bool> loadAndPlay(List<String> urls);

  /// 当前是否有已加载的音源（对应原版 !!audio.src）
  bool get hasSource;

  bool get isPlaying;
  double get positionSec;
  double get durationSec;

  Future<void> play();
  Future<void> pause();

  /// 跳转（秒）；duration 已知时由 AppState 负责夹取
  Future<void> seek(double sec);

  /// 0..1
  double get volume;
  Future<void> setVolume(double v);

  /// 事件流（AppState 订阅）
  Stream<EngineEvent> get events;

  /// 实时频谱（0..1 频带数据，约 256 bins；无数据返回 null）
  /// 对应原版 analyser.getByteFrequencyData
  Float32List? get fft;

  /// 时域波形（约 -1..1 样本；无数据返回 null）
  /// 对应原版 analyser.getByteTimeDomainData（RMS 响度用）
  Float32List? get wave;

  /// 释放（不再使用）
  void dispose();
}
