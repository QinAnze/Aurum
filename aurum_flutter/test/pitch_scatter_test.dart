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
    for (final path in [
      'assets/EBGaramond-Regular.ttf',
      'assets/EBGaramond-SemiBold.ttf',
    ]) {
      loader.addFont(
          Future.value(ByteData.sublistView(File(path).readAsBytesSync())));
    }
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
    for (var i = 0; i < 600; i++) {
      c.spawn('C5', rnd: rnd);
      if (c.words.length < prev) cleared = true;
      prev = c.words.length;
      expect(c.words.length, lessThanOrEqualTo(cap));
    }
    expect(cleared, isTrue, reason: '铺满应清空重来');
    expect(c.words, isNotEmpty);
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

  test('文本样式：衬线字体、不带发光（无 shadows）', () {
    final s = PitchScatterController.styleFor(24);
    expect(s.shadows, isNull);
    expect(s.fontFamily, 'AurumSerif');
    // 巨型字走细衬线的 Regular，其余走 SemiBold
    expect(PitchScatterController.styleFor(24, giant: true).fontWeight,
        FontWeight.w400);
    expect(s.fontWeight, FontWeight.w600);
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
    final c = make();
    final rnd = math.Random(4);
    for (var i = 0; i < 78; i++) {
      c.spawn('C#6', rnd: rnd);
    }
    expect(c.words.length, greaterThan(40));
    _expectNoOverlap(c);
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
