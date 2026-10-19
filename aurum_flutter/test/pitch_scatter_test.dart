// 乐器段「整块背景随机散落」音高字的落位规则单测（纯数据，无 widget）。
//
// 会真的把 assets/ 里的衬线体加载进来：flutter_test 默认用占位字体，
// 每个字符固定 1em 宽，'C#6' 会比真实字形宽一倍多 —— 覆盖率与落位
// 结论全不可信。加载真实字体后，这里量到的尺寸就是运行时画的尺寸。
import 'dart:io';
import 'dart:math' as math;

import 'package:aurum/effects/pitch_scatter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const size = Size(1280, 800);

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final loader = FontLoader(PitchScatterController.fontFamily);
    loader.addFont(Future.value(ByteData.sublistView(
        File('assets/HYPixel11pxU-2.ttf').readAsBytesSync())));
    await loader.load();
  });

  PitchScatterController make() => PitchScatterController()..layout(size);

  test('落点覆盖整个背景，不局限在下半屏', () {
    final c = make();
    final rnd = math.Random(7);
    for (var i = 0; i < 60; i++) {
      expect(c.spawn('E5', rnd: rnd), isTrue, reason: '第 $i 个应能落位');
    }
    expect(c.words, hasLength(60));
    for (final w in c.words) {
      expect(w.y, greaterThanOrEqualTo(0));
      expect(w.y, lessThan(size.height));
      expect(w.x, greaterThanOrEqualTo(0));
      expect(w.x, lessThan(size.width));
    }

    // 上半屏必须也有字：之前只从 62% 高度往下撒，顶部是空的
    final upper = c.words.where((w) => w.y < size.height * 0.35).length;
    final lower = c.words.where((w) => w.y > size.height * 0.65).length;
    expect(upper, greaterThan(0), reason: '顶部背景也要铺上');
    expect(lower, greaterThan(0), reason: '底部也要铺上');
  });

  test('互不重叠（每个都有独立位置）', () {
    final c = make();
    final rnd = math.Random(3);
    for (var i = 0; i < 30; i++) {
      c.spawn('A4', rnd: rnd);
    }
    final seen = <String>{};
    for (final w in c.words) {
      seen.add('${w.x.toStringAsFixed(2)},${w.y.toStringAsFixed(2)}');
    }
    expect(seen, hasLength(c.words.length));
  });

  test('放满清空后继续：容量上限内不会无限膨胀', () {
    final c = make();
    final cap = PitchScatterController.computeCapacity(size);
    final rnd = math.Random(11);
    var cleared = false;
    var prev = 0;
    for (var i = 0; i < 900; i++) {
      c.spawn('C5', rnd: rnd);
      // 铺满后不再硬清空，而是把字吸走 —— 要推进才会真的腾空
      c.tick(0.05);
      if (c.words.length < prev) cleared = true;
      prev = c.words.length;
      expect(c.words.length, lessThanOrEqualTo(cap));
    }
    expect(cleared, isTrue, reason: '铺满应吸走重来');
    expect(c.words, isNotEmpty);
  });

  test('铺满清屏是「向下坠落」而不是瞬间消失', () {
    final c = make();
    final rnd = math.Random(13);
    // 一直放，直到铺满（塞不进缝会累加，够了就自动换批）
    for (var i = 0; i < 200; i++) {
      c.spawn('A4', rnd: rnd);
    }
    expect(c.words, isNotEmpty, reason: '铺满那一刻字还在屏上');
    expect(c.exiting, isTrue, reason: '应当进入退场，而不是直接清空');
    expect(c.sucking, isFalse, reason: '铺满换批不该用吸入（那是转场语言）');

    // 推进一小段：字往下掉、并且变小变淡
    for (var t = 0.0; t < 0.22; t += 0.016) {
      c.tick(0.016);
    }
    expect(c.words, isNotEmpty);
    final falling = c.words.where((w) => w.pose.dy > 0);
    expect(falling, isNotEmpty, reason: '应当看到字在往下掉');
    expect(c.words.any((w) => w.pose.alpha < 1), isTrue, reason: '下落要淡出');

    // 落完才清空
    for (var t = 0.0; t < 0.9; t += 0.016) {
      c.tick(0.016);
    }
    expect(c.isEmpty, isTrue);
    expect(c.exiting, isFalse);
  });

  test('clear 清空；尺寸变化不影响正确性', () {
    final c = make();
    final rnd = math.Random(1);
    for (var i = 0; i < 10; i++) {
      c.spawn('D4', rnd: rnd);
    }
    expect(c.words, isNotEmpty);
    c.clear();
    expect(c.isEmpty, isTrue);

    c.layout(const Size(640, 480));
    expect(c.spawn('G4', rnd: rnd), isTrue);
    expect(c.words, hasLength(1));
  });

  test('文本样式：像素字体、不带发光（无 shadows）', () {
    final s = PitchScatterController.styleFor(24);
    expect(s.shadows, isNull);
    expect(s.fontFamily, 'AurumPixel');
    // 像素字只有一个字重：传 bold 会让引擎合成假粗体，把像素边糊掉
    expect(s.fontWeight, isNull);
  });

  test('字号跨度极大：既有小字也有巨型字', () {
    final c = make();
    final rnd = math.Random(5);
    for (var i = 0; i < 200; i++) {
      c.spawn('F4', rnd: rnd);
    }
    final sizes = c.words.map((w) => w.size).toList();
    final min = sizes.reduce(math.min);
    final max = sizes.reduce(math.max);
    expect(sizes.toSet().length, greaterThan(20), reason: '每个字大小应随机');
    // 基准 = 短边 800 × 0.045 = 36；巨型上限约 5.2 倍 → 差距要 6 倍以上
    expect(max / min, greaterThan(6), reason: '大小差距要拉得开');
    expect(min, lessThan(30), reason: '要有小字垫底');
    expect(max, greaterThan(120), reason: '要有巨大的字');
    expect(c.words.where((w) => w.giant).isNotEmpty, isTrue);
  });

  test('横排与竖排混排：竖排逐字换行', () {
    final c = make();
    final rnd = math.Random(21);
    for (var i = 0; i < 120; i++) {
      c.spawn('C#4', rnd: rnd);
    }
    final vertical = c.words.where((w) => w.vertical).toList();
    final horizontal = c.words.where((w) => !w.vertical).toList();
    expect(vertical, isNotEmpty, reason: '要有竖排的字');
    expect(horizontal, isNotEmpty, reason: '也要有横排的字');

    // 竖排：每个字符一行（升号并到音名后）；横排保持原样
    expect(vertical.first.text, 'C#\n4');
    expect(horizontal.first.text, 'C#4');
    // 纯自然音就是逐字换行
    expect(PitchScatterController.verticalTextOf('G5'), 'G\n5');
    // 竖排样式行距收紧
    final vs = PitchScatterController.styleFor(20, vertical: true);
    expect(vs.height, lessThan(1.0));
  });

  test('字形矩形两两不相交（落位避让真的生效）', () {
    // 次数控制在「一轮还没铺满」以内：中途清屏会把检查对象清掉
    final c = make();
    final rnd = math.Random(4);
    for (var i = 0; i < 40; i++) {
      c.spawn('C#6', rnd: rnd);
    }
    expect(c.words.length, greaterThan(20));
    _expectNoOverlap(c);
  });

  /* ---------------- 入场动画 ---------------- */

  test('入场：刚落位时是「还没出现」，0.5s 后归位', () {
    final c = make();
    c.spawn('E5', rnd: math.Random(2));
    final w = c.words.single;
    expect(w.anim, 0, reason: '刚落位还没开始演');
    expect(w.pose.alpha, 0, reason: '入场第一帧应当不可见');

    // 推进半程：应当已经可见、且还带着位移/旋转/缩放中的某一个
    for (var i = 0; i < 15; i++) {
      c.tick(0.016);
    }
    expect(w.anim, greaterThan(0.3));
    expect(w.pose.alpha, greaterThan(0.0));

    // 跑满 0.5s：姿态必须完全归位，否则字会永远歪着
    for (var i = 0; i < 40; i++) {
      c.tick(0.016);
    }
    expect(w.anim, 1);
    expect(w.pose.isIdentity, isTrue,
        reason: '入场结束后 dx/dy/缩放/旋转/透明度都要回到默认');
  });

  test('入场：六种动画都会出现，且都给得出非零的姿态变化', () {
    final seen = <ScatterEntrance>{};
    for (var seed = 0; seed < 60; seed++) {
      final c = make();
      c.spawn('A4', rnd: math.Random(seed));
      final w = c.words.single;
      seen.add(w.entrance);
      // 推进到 30% 左右，看姿态有没有动
      for (var i = 0; i < 10; i++) {
        c.tick(0.016);
      }
      expect(w.pose.isIdentity, isFalse,
          reason: '${w.entrance} 在入场途中应当有位移/旋转/缩放');
    }
    expect(seen.length, ScatterEntrance.values.length,
        reason: '六种入场动画都要能被抽到');
  });

  /* ---------------- 被吸向中心 ---------------- */

  test('吸入：字向中心靠拢、缩小、淡出，最后清空', () {
    final c = make();
    final rnd = math.Random(9);
    for (var i = 0; i < 30; i++) {
      c.spawn('C5', rnd: rnd);
    }
    // 先把入场演完，免得两套动画叠在一起看不清
    for (var i = 0; i < 40; i++) {
      c.tick(0.016);
    }
    final before = List.of(c.words);
    const target = Offset(640, 400);
    c.suckTo(target);
    expect(c.sucking, isTrue);
    expect(before.first.suckDelay, greaterThanOrEqualTo(0));
    expect(before.first.suckDelay, lessThanOrEqualTo(
        PitchScatterController.suckSpread + 1e-9));

    // 演到一半：还在，但已经往中心挪了、并且变小了
    final half = (PitchScatterController.suckSpread +
            PitchScatterController.suckSec) /
        2;
    for (var t = 0.0; t < half; t += 0.016) {
      c.tick(0.016);
    }
    expect(c.words, isNotEmpty);
    final mid = c.words.first;
    final startDist =
        (Offset(mid.centerX, mid.centerY) - target).distance;
    final nowDist = (Offset(mid.centerX + mid.pose.dx, mid.centerY + mid.pose.dy) -
            target)
        .distance;
    expect(nowDist, lessThan(startDist + 1e-6), reason: '应当朝中心移动');
    expect(mid.pose.sx, lessThan(1.0), reason: '应当缩小');
    expect(mid.pose.alpha, lessThan(1.0), reason: '应当淡出');

    // 跑完：清空、sucking 归 false
    for (var i = 0; i < 120; i++) {
      c.tick(0.016);
    }
    expect(c.isEmpty, isTrue);
    expect(c.sucking, isFalse);
  });

  test('退场期间不接受新字；cancelExit 能把字留在原地', () {
    final c = make();
    for (var i = 0; i < 10; i++) {
      c.spawn('D4', rnd: math.Random(i));
    }
    c.suckTo(const Offset(600, 400));
    expect(c.spawn('E5', rnd: math.Random(1)), isFalse,
        reason: '正在吸走时不能让新字把这一屏清掉');

    c.cancelExit();
    expect(c.sucking, isFalse);
    expect(c.words, isNotEmpty, reason: '取消吸入不应把字弄没');
    for (final w in c.words) {
      expect(w.pose.isIdentity, isTrue, reason: '取消后要回到静止姿态');
    }
  });

  /* ---------------- 发光与脉动 ---------------- */

  test('光晕：glow 为 0 时不带 shadows，越大越亮', () {
    final off = PitchScatterController.styleFor(40);
    expect(off.shadows, isNull, reason: '没有高潮就不要光晕');

    final on = PitchScatterController.styleFor(40, glow: 0.6, blur: 12);
    expect(on.shadows, hasLength(2), reason: '两层同色光晕（近亮远大）');
    final weak = PitchScatterController.styleFor(40, glow: 0.2, blur: 4);
    expect(weak.shadows!.first.color.a, lessThan(on.shadows!.first.color.a),
        reason: '光晕强度应随 glow 变亮');
    expect(on.shadows!.last.blurRadius, greaterThan(0));
  });

  test('脉动：setPulse 量化，避免每帧重排版', () {
    final c = make();
    c.setPulse(1.23456, 0.5001, 7.31);
    // 量化到 1% / 1/24 / 0.5px
    expect(c.pulse, closeTo(1.23, 1e-9));
    expect(c.glow, closeTo(12 / 24, 1e-9));
    expect(c.blur, closeTo(7.5, 1e-9));

    // 极小的抖动不该改变已量化的值（否则每帧都是新样式）
    c.setPulse(1.2301, 0.5004, 7.34);
    expect(c.pulse, closeTo(1.23, 1e-9));
    expect(c.glow, closeTo(12 / 24, 1e-9));
    expect(c.blur, closeTo(7.5, 1e-9));
  });

  testWidgets('脉动真的把字放大（渲染层矩阵）', (tester) async {
    final c = make();
    c.spawn('E5', rnd: math.Random(3));
    for (var i = 0; i < 40; i++) {
      c.tick(0.016); // 演完入场
    }
    Future<double> maxScale() async {
      await tester.pumpWidget(MaterialApp(
        home: SizedBox(
          width: 1280,
          height: 800,
          child: PitchScatter(controller: c),
        ),
      ));
      await tester.pump();
      var m = 0.0;
      for (final t in tester.widgetList<Transform>(find.byType(Transform))) {
        final v = t.transform.storage[0];
        if (v > m) m = v;
      }
      // 缩放为 1 时 widget 会跳过 Transform，此时就是原尺寸
      return m == 0 ? 1.0 : m;
    }

    c.setPulse(1, 0, 0);
    expect(await maxScale(), closeTo(1.0, 0.001), reason: '没高潮时原尺寸');

    c.setPulse(1.35, 1, 24);
    expect(await maxScale(), closeTo(1.35, 0.001), reason: '高潮时放大');
  });

  test('颜色取自封面取色板，不是清一色白', () {
    final c = make()
      ..setPalette(const [
        Color(0xFFC0392B), // 红
        Color(0xFF2E86C1), // 蓝
        Color(0xFF27AE60), // 绿
      ]);
    final rnd = math.Random(9);
    for (var i = 0; i < 20; i++) {
      c.spawn('A4', rnd: rnd);
    }
    final hues =
        c.words.map((w) => HSLColor.fromColor(w.color).hue.round()).toSet();
    expect(hues.length, greaterThan(1), reason: '颜色应来自封面色板的多个色相');

    // 白/近白（饱和度极低）不该占多数
    final washed = c.words
        .where((w) => HSLColor.fromColor(w.color).saturation < 0.15)
        .length;
    expect(washed, lessThan(c.words.length ~/ 2));
  });

  test('没有色板时退回白色兜底', () {
    final c = make();
    c.spawn('B3', rnd: math.Random(2));
    expect(c.words.single.color.r, closeTo(1.0, 0.01));
    expect(c.words.single.color.g, closeTo(1.0, 0.01));
  });
}

/// 数据层校验：任意两个字的矩形都不该相交。
/// 视觉上如果仍然压在一起，说明字形超出了 TextPainter 报的框（衬线外伸），
/// 那是绘制问题，不是落位问题 —— 用这条把两者分开。
void _expectNoOverlap(PitchScatterController c) {
  for (var i = 0; i < c.words.length; i++) {
    for (var j = i + 1; j < c.words.length; j++) {
      final a = c.words[i];
      final b = c.words[j];
      final hit = a.x < b.x + b.width &&
          a.x + a.width > b.x &&
          a.y < b.y + b.height &&
          a.y + a.height > b.y;
      expect(hit, isFalse,
          reason: '${a.note}#$i 与 ${b.note}#$j 的矩形相交：'
              '${a.x},${a.y},${a.width}x${a.height} vs '
              '${b.x},${b.y},${b.width}x${b.height}');
    }
  }
}
