// 本地列表「点击错位」回归测试。
//
// 用户报（2026-10-18）：本地模式点第一首正常，点后面的歌位置就不正常，
// 鼠标必须悬停在某首歌上才能点到那首。10-17 修的是「无封面旧封面残留」，
// 与本测试针对的索引/命中问题是两条不同的链路。
//
// 策略：用桩引擎驱动真实 widget 树（真实命中测试），逐行点击，
// 断言 playAt 落到被点行对应的曲目上。

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

List<Track> _localTracks(int n) => [
      for (var i = 0; i < n; i++)
        Track(
          id: 'D:\\Music\\album\\song-$i.mp3',
          name: '本地歌曲 $i',
          artist: '歌手',
          album: '专辑',
          source: 'file',
        ),
    ];

void main() {
  // 桌面布局（≥880px）才会把侧栏内联在左侧；默认 800×600 会走窄屏抽屉，
  // 侧栏被 AnimatedSlide 挪到屏幕外，点不到。
  void useDesktopView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 860);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  final listFinder = find.byType(ListView).first;

  /// 把目标行滚进视口再点（ListView 懒加载，不可见的行还没构建）。
  /// 点击点取「行中心与视口中心的交集」——模拟真人点行的可见部分，
  /// 避免点到被裁掉一半的行的几何中心（会落到列表外，什么也不中）。
  Future<void> tapRow(WidgetTester tester, String name) async {
    var guard = 0;
    while (true) {
      final finder = find.text(name);
      final visible = finder.evaluate().isNotEmpty &&
          (() {
            final r = tester.getRect(finder);
            final vp = tester.getRect(listFinder);
            return r.center.dy > vp.top + 4 && r.center.dy < vp.bottom - 4;
          })();
      if (visible) break;
      if (guard++ > 120) fail('滚了 120 次还看不到 $name');
      await tester.drag(listFinder, const Offset(0, -100));
      await tester.pump(const Duration(milliseconds: 80));
    }
    await tester.pump(const Duration(milliseconds: 400)); // 等滚动停稳
    await tester.tap(find.text(name));
    await tester.pump();
  }

  testWidgets('本地列表逐行点击：点第 i 行必须放第 i 首', (tester) async {
    useDesktopView(tester);
    final app = AppState(engine: _StubEngine(), autoStart: false);
    app.localTracks = _localTracks(30);
    app.setTab(LibraryTab.local);

    await tester.pumpWidget(AurumApp(app: app));
    // 放行错峰入场动画（30ms/行、上限 420ms + 320ms 时长）
    await tester.pump(const Duration(milliseconds: 900));

    for (var i = 0; i < 30; i++) {
      await tapRow(tester, '本地歌曲 $i');
      expect(app.current?.name, '本地歌曲 $i',
          reason: '点击第 $i 行后 current 应是被点行');
      expect(app.index, i, reason: '点击第 $i 行后 index 应为 $i');
    }

    await tester.pump(const Duration(seconds: 2)); // 放行残留 stagger 定时器
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    app.dispose();
  });

  testWidgets('长列表滚动后点击：命中仍与视觉行一致', (tester) async {
    useDesktopView(tester);
    final app = AppState(engine: _StubEngine(), autoStart: false);
    app.localTracks = _localTracks(60);
    app.setTab(LibraryTab.local);

    await tester.pumpWidget(AurumApp(app: app));
    await tester.pump(const Duration(milliseconds: 900));

    // 直接拖到第 25 行附近再开始逐行点
    await tester.drag(listFinder, const Offset(0, -1600));
    await tester.pump(const Duration(milliseconds: 500));

    for (var i = 25; i < 45; i++) {
      await tapRow(tester, '本地歌曲 $i');
      expect(app.current?.name, '本地歌曲 $i',
          reason: '滚动后点击第 $i 行');
      expect(app.index, i);
    }

    await tester.pump(const Duration(seconds: 2)); // 放行残留 stagger 定时器
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    app.dispose();
  });

  testWidgets('入场动画中途点击：仍落在正确行', (tester) async {
    useDesktopView(tester);
    final app = AppState(engine: _StubEngine(), autoStart: false);
    app.localTracks = _localTracks(30);
    app.setTab(LibraryTab.local);

    await tester.pumpWidget(AurumApp(app: app));
    // 只放行 200ms：第 7+ 行还在错峰滑入途中（opacity 0 / 偏移 -8px）
    await tester.pump(const Duration(milliseconds: 200));

    for (var i = 0; i < 9; i++) {
      await tester.tap(find.text('本地歌曲 $i'));
      await tester.pump();
      expect(app.current?.name, '本地歌曲 $i',
          reason: '动画中途点击第 $i 行');
      expect(app.index, i);
    }

    await tester.pump(const Duration(seconds: 2)); // 放行残留 stagger 定时器
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    app.dispose();
  });
}
