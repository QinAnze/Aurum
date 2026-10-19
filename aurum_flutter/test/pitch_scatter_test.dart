// 乐器段「底部随机散落」音高字的落位规则单测（纯数据，无 widget）。
import 'dart:math' as math;

import 'package:aurum/effects/pitch_scatter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const size = Size(1280, 800);

  PitchScatterController make() =>
      PitchScatterController()..layout(size);

  test('落点在底部横带内，且在屏幕内', () {
    final c = make();
    final rnd = math.Random(7);
    for (var i = 0; i < 40; i++) {
      expect(c.spawn('E5', rnd: rnd), isTrue, reason: '第 $i 个应能落位');
    }
    expect(c.words, hasLength(40));
    final bandTop = size.height * PitchScatterController.bandTop;
    for (final w in c.words) {
      expect(w.y, greaterThanOrEqualTo(bandTop - 0.01));
      expect(w.y, lessThan(size.height));
      expect(w.x, greaterThanOrEqualTo(0));
      expect(w.x, lessThan(size.width));
    }
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
    for (var i = 0; i < 400; i++) {
      c.spawn('C5', rnd: rnd);
      if (c.words.length < prev) cleared = true;
      prev = c.words.length;
      expect(c.words.length, lessThanOrEqualTo(cap));
    }
    expect(cleared, isTrue, reason: '放满应清空重来');
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

  test('文本样式不带发光（无 shadows）', () {
    final s = PitchScatterController.styleFor(24);
    expect(s.shadows, isNull);
    expect(s.fontFamily, 'SmileySans');
  });

  test('字号不是一律相同：有大小差异', () {
    final c = make();
    final rnd = math.Random(5);
    for (var i = 0; i < 24; i++) {
      c.spawn('F4', rnd: rnd);
    }
    final sizes = c.words.map((w) => w.size).toSet();
    expect(sizes.length, greaterThan(4), reason: '每个字大小应随机抖动');
    final min = c.words.map((w) => w.size).reduce(math.min);
    final max = c.words.map((w) => w.size).reduce(math.max);
    expect(max / min, greaterThan(1.5), reason: '大小差异要看得见');
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
    final hues = c.words.map((w) => HSLColor.fromColor(w.color).hue.round()).toSet();
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
