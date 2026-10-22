// Aurum · UI smoke test：用桩引擎把整个 HomePage widget 树编译并构建出来，
// 验证 main.dart → HomePage → 全部 widgets 的装配无误（不触网、不出图）。
import 'dart:async';
import 'dart:typed_data';

import 'package:aurum/audio/player_engine.dart';
import 'package:aurum/effects/pitch_scatter.dart';
import 'package:aurum/main.dart';
import 'package:aurum/state/app_state.dart';
import 'package:aurum/widgets/glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _StubEngine implements PlayerEngine {
  @override
  Future<void> init() async {}

  @override
  Future<bool> loadAndPlay(List<String> urls) async => false;

  @override
  bool get hasSource => false;

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

/// 返回 [finder] 命中的元素所在 Stack 的 children 下标，找不到返回 -1。
int _stackIndexOf(WidgetTester tester, Finder finder) {
  if (finder.evaluate().isEmpty) return -1;
  final node = finder.evaluate().first;
  Element? direct = node;
  int? index;
  node.visitAncestorElements((up) {
    if (up.widget is Stack) {
      final stack = up.widget as Stack;
      var i = 0;
      for (final child in stack.children) {
        if (identical(child, direct!.widget)) {
          index = i;
          return false;
        }
        i++;
      }
      return false;
    }
    direct = up;
    return true;
  });
  return index ?? -1;
}

void main() {
  testWidgets('HomePage 全树构建 smoke', (tester) async {
    // autoStart: false —— 启动搜索会打真实网络：CI 上接口通了会填满在线列表，
    // 「播放列表」标签变成「周杰伦 · N 首」，断言就挂了（本地网络不通所以一直没暴露）。
    final app = AppState(engine: _StubEngine(), autoStart: false);

    await tester.pumpWidget(AurumApp(app: app));
    // 放行启动期异步（本地 API 探测 + 默认搜索）
    await tester.runAsync(
        () async => await Future.delayed(const Duration(milliseconds: 800)));
    await tester.pump();

    // 品牌与总开关
    expect(find.text('Aurum'), findsOneWidget);
    expect(find.text('ON'), findsOneWidget);
    // 空态：标题/歌手占位 + 列表空态
    expect(find.text('还没有放歌哦…'), findsOneWidget);
    expect(find.text('点一首嘛？人家等着呢'), findsOneWidget);
    expect(find.textContaining('想听什么就自己搜啦'), findsOneWidget);
    expect(find.textContaining('播放列表'), findsOneWidget);
    // 控件行：播放键 + 三个线性图标存在
    expect(find.byType(GestureDetector), findsWidgets);

    // 交互：切换总开关 → OFF
    await tester.tap(find.text('ON'));
    await tester.pump();
    expect(find.text('OFF'), findsOneWidget);

    // 卸载整棵树（释放 ticker），并显式销毁 AppState（取消 toast 定时器）
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    app.dispose();
  });

  testWidgets('逐特效开关：默认收起，点开才浮出四行，各自独立', (tester) async {
    final app = AppState(engine: _StubEngine(), autoStart: false);
    await tester.pumpWidget(AurumApp(app: app));
    await tester.runAsync(
        () async => await Future.delayed(const Duration(milliseconds: 500)));
    await tester.pump();

    // 收起态：只剩一枚胶囊，四行标签不在树里
    final chip = find.byKey(const ValueKey('fx-chip'));
    expect(chip, findsOneWidget);
    for (final label in ['词云', '频谱', '打光', '音高']) {
      expect(find.text(label), findsNothing, reason: '收起时不该占位');
    }

    // 胶囊与总开关同一行、同一中线（用户要求「处于同一高度」）
    final toggleRect = tester.getRect(find.text('ON'));
    final chipRect = tester.getRect(chip);
    expect(
      (chipRect.center.dy - toggleRect.center.dy).abs(),
      lessThan(2),
      reason: '特效胶囊要和总开关同一中线',
    );

    // 点开 → 四行浮出，且都在总开关下方
    await tester.tap(chip);
    // viz 的 ticker 常驻，pumpAndSettle 会一直等下去，用定长 pump
    await tester.pump(const Duration(milliseconds: 260));
    for (final label in ['词云', '频谱', '打光', '音高']) {
      expect(find.text(label), findsOneWidget);
    }
    final toggleY = tester.getCenter(find.text('ON')).dy;
    for (final label in ['词云', '频谱', '打光', '音高']) {
      expect(tester.getCenter(find.text(label)).dy, greaterThan(toggleY));
    }

    // 单点「打光」：关掉它，其他三项与总开关不受影响
    await tester.tap(find.byKey(const ValueKey('fx-check-kick')));
    await tester.pump();
    expect(app.fxOn, isTrue);
    expect(app.fxKick, isFalse);
    expect(app.fxCloud && app.fxSpectrum && app.fxPitch, isTrue);
    expect(app.fxItemOn('kick'), isFalse);
    expect(app.fxItemOn('cloud'), isTrue);

    // 点空白处收起（展开时浮层的遮罩会挡住总开关，得先收）
    await tester.tapAt(const Offset(6, 6));
    await tester.pump(const Duration(milliseconds: 260));
    expect(find.text('词云'), findsNothing, reason: '点外部应收起');

    // 总开关关掉 → 所有特效实测都关
    await tester.tap(find.text('ON'));
    await tester.pump();
    expect(app.fxOn, isFalse);
    expect(app.fxItemOn('cloud'), isFalse);

    // 再展开点单个 → 会顺手把总开关打开
    await tester.tap(chip);
    await tester.pump(const Duration(milliseconds: 260));
    await tester.tap(find.byKey(const ValueKey('fx-check-cloud')));
    await tester.pump();
    expect(app.fxOn, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    app.dispose();
  });

  testWidgets('音高散落铺在背景层，不压住播放器面板', (tester) async {
    final app = AppState(engine: _StubEngine(), autoStart: false);
    await tester.pumpWidget(AurumApp(app: app));
    await tester.runAsync(
        () async => await Future.delayed(const Duration(milliseconds: 500)));
    await tester.pump();

    // 音高散落与播放器面板的同层顺序：散落必须在面板**之前**（更靠下）
    final panelIdx = _stackIndexOf(tester, find.byType(GlassPanel).first);
    final scatterIdx = _stackIndexOf(tester, find.byType(PitchScatter));
    expect(scatterIdx, isNonNegative, reason: '音高特效开着时散落层应存在');
    expect(scatterIdx, lessThan(panelIdx),
        reason: '散落是背景层，必须在播放器面板之下');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    app.dispose();
  });

  testWidgets('窄屏（<880px）走抽屉布局', (tester) async {
    // autoStart: false —— 启动搜索会打真实网络：CI 上接口通了会填满在线列表，
    // 「播放列表」标签变成「周杰伦 · N 首」，断言就挂了（本地网络不通所以一直没暴露）。
    final app = AppState(engine: _StubEngine(), autoStart: false);

    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(AurumApp(app: app));
    await tester.runAsync(
        () async => await Future.delayed(const Duration(milliseconds: 500)));
    await tester.pump();

    // 窄屏：菜单键出现（侧栏改为抽屉）
    expect(find.byKey(const ValueKey('menu-button')), findsOneWidget);
    // 界面仍完整
    expect(find.text('还没有放歌哦…'), findsOneWidget);
    // 点菜单键 → 抽屉滑入（AnimatedSlide 380ms）
    await tester.tap(find.byKey(const ValueKey('menu-button')));
    await tester.pump(const Duration(milliseconds: 450));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    app.dispose();
  });
}
