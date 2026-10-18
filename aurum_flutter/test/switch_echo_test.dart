// 回归：切歌时引擎「停旧歌」的回声不能被当成自然播完。
//
// flutter_soloud 对 stop() / disposeSource() 也会给音源发
// handleIsNoMoreValid（插件文档：Every stopped voice emits a
// handleIsNoMoreValid event on its source）。SoloudEngine 以前照单全收 →
// AppState 收到 EngineEnded → next()，表现为「点第 i 首却放第 i+1 首」。
//
// 这里用桩引擎复现该回声（同步投递 = 加载期间到达），锁定 AppState 的防护；
// 异步到达的情况由 SoloudEngine._stopInternal「先退订事件再清场」兜住。

import 'dart:async';
import 'dart:typed_data';

import 'package:aurum/audio/player_engine.dart';
import 'package:aurum/models.dart';
import 'package:aurum/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

class _EchoEngine implements PlayerEngine {
  final _events = StreamController<EngineEvent>.broadcast(sync: true);
  bool _hasSource = false;

  @override
  Future<void> init() async {}

  @override
  Future<bool> loadAndPlay(List<String> urls) async {
    // 模拟真实引擎：加载新歌前先停旧 voice → 旧 voice 发 handleIsNoMoreValid
    if (_hasSource) _events.add(EngineEnded());
    _hasSource = true;
    _events.add(EnginePlayingChanged(true));
    return true;
  }

  @override
  bool get hasSource => _hasSource;
  @override
  bool get isPlaying => true;
  @override
  double get positionSec => 0;
  @override
  double get durationSec => 180;
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(double sec) async {}
  @override
  double get volume => 1;
  @override
  Future<void> setVolume(double v) async {}
  @override
  Stream<EngineEvent> get events => _events.stream;
  @override
  Float32List? get fft => null;
  @override
  Float32List? get wave => null;
  @override
  void dispose() => _events.close();
}

List<Track> _tracks(int n) => [
      for (var i = 0; i < n; i++)
        Track(
          id: 'D:\\Music\\song-$i.mp3',
          name: '本地歌曲 $i',
          artist: '歌手',
          album: '专辑',
          source: 'file',
        ),
    ];

void main() {
  test('切歌时「停旧歌」的 ended 回声不能触发自动跳下一首', () async {
    final engine = _EchoEngine();
    final app = AppState(engine: engine, autoStart: false);
    addTearDown(app.dispose);
    app.localTracks = _tracks(10);
    app.setTab(LibraryTab.local);

    await app.playAt(0);
    expect(app.current?.name, '本地歌曲 0');

    await app.playAt(3);
    await Future<void>.delayed(Duration.zero); // 放行事件流
    expect(app.current?.name, '本地歌曲 3',
        reason: '回声被当成自然播完会跳到第 4 首 —— 正是用户报的「点一首放下一首」');
    expect(app.index, 3);
  });
}
