// 验证「滚动回收的行会不会重放入场动画」。
//
// _TrackRow.initState 里有 30ms×index（上限 420ms）延迟 + 320ms 淡入。
// ListView.builder 会把滚出缓存区的行销毁，滚回来时新建 State → 动画重放。
// 若重放，用户滚动长列表时会看到行反复从透明状态闪入，
// 点击时“点在看不见的行上”——即用户报的「点后面的歌位置不正常」。
import 'dart:async';
import 'dart:typed_data';

import 'package:aurum/audio/player_engine.dart';
import 'package:aurum/main.dart';
import 'package:aurum/models.dart';
import 'package:aurum/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _StubEngine implements PlayerEngine {
  @override
  Future<void> init() async {}
  @override
  Future<bool> loadAndPlay(List<String> urls) async => true;
  @override
  bool get hasSource => true;
  @override
  bool get isPlaying => false;
  @override
  double get positionSec => 0;
  @override
  double get durationSec => 0;
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(double sec) async {}
  @override
  double get volume => 1.0;
  @override
  Future<void> setVolume(double v) async {}
  @override
  Stream<EngineEvent> get events => const Stream.empty();
  @override
  Float32List? get fft => null;
  @override
  Float32List? get wave => null;
  @override
  void dispose() {}
}

void main() {
  testWidgets('滚动进入视口的行：透明度应立即为 1，不应重放入场动画', (tester) async {
    tester.view.physicalSize = const Size(1280, 860);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final app = AppState(engine: _StubEngine(), autoStart: false);
    app.localTracks = [
      for (var i = 0; i < 40; i++)
        Track(
          id: 'D:\\Music\\album\\song-$i.mp3',
          name: '本地歌曲 $i',
          artist: '歌手',
          album: '专辑',
          source: 'file',
        ),
    ];
    app.setTab(LibraryTab.local);

    await tester.pumpWidget(AurumApp(app: app));
    // 逐帧推进 1.2s：Future.delayed 触发 forward 后，动画要靠后续帧才能走完
    // （不能用 pumpAndSettle——封面呼吸光晕是无限循环动画，永远 settle 不了）
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 初始状态：前几行已完成入场（opacity 1）
    double opacityOf(String name) {
      final ops = find
          .ancestor(of: find.text(name), matching: find.byType(Opacity))
          .evaluate();
      return ops.isEmpty ? -1 : (ops.last.widget as Opacity).opacity;
    }

    expect(opacityOf('本地歌曲 0'), 1.0);

    // 往下滚 8 行左右，让第 20 行附近进入视口
    final listFinder = find.byType(ListView).first;
    await tester.drag(listFinder, const Offset(0, -1300));
    await tester.pump(const Duration(milliseconds: 100)); // 滚动停稳后只过 100ms
    await tester.pump();

    expect(find.text('本地歌曲 20'), findsOneWidget);
    final op = opacityOf('本地歌曲 20');
    expect(op, 1.0,
        reason: '滚动回收重建的行不应从透明状态重新淡入（最多还要先等 '
            '420ms  stagger 延迟），否则用户会看到行闪入、点到看不见的行');

    await tester.pump(const Duration(seconds: 2)); // 放行残留定时器
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    app.dispose();
  });
}
