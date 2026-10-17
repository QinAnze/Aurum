// Aurum · 封面取色（背景主题色）回归测试 —— 对应用户报的 bug ②「背景色不会随封面变」。
// 真实的下载链路依赖网络，这里把「像素 → 主题色」的数学拆成纯函数来钉死；
// 下载链路的关键（CDN 候选 host）由 test/viz_test.dart 的 imageUrlCandidates 覆盖。
import 'dart:typed_data';

import 'package:aurum/api/music_api.dart';
import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';

/// 本版本 Color.r/g/b 返回 0..1 归一化值，统一换算回 0..255 便于断言
int r255(Color c) => (c.r * 255).round();
int g255(Color c) => (c.g * 255).round();
int b255(Color c) => (c.b * 255).round();

/// 构造 rawStraightRgba 的 ByteData
ByteData _rgba(List<List<int>> pixels) {
  final data = Uint8List(pixels.length * 4);
  for (var i = 0; i < pixels.length; i++) {
    data[i * 4] = pixels[i][0];
    data[i * 4 + 1] = pixels[i][1];
    data[i * 4 + 2] = pixels[i][2];
    data[i * 4 + 3] = 255;
  }
  return data.buffer.asByteData();
}

List<List<int>> _solid(int r, int g, int b, int n) =>
    List.generate(n, (_) => [r, g, b]);

void main() {
  group('quantizeCoverColors', () {
    test('纯洋红封面 → c1/c2 都是洋红，palette 非空', () {
      final res = quantizeCoverColors(_rgba(_solid(220, 40, 140, 64)));
      expect(res, isNotNull);
      final (c1, c2, palette) = res!;
      // c1 是均值色
      expect(r255(c1), closeTo(220, 3));
      expect(g255(c1), closeTo(40, 3));
      expect(b255(c1), closeTo(140, 3));
      // c2 是高饱和单像素（这里整张图同色 → 与 c1 一致）
      expect(r255(c2), closeTo(220, 3));
      expect(b255(c2), closeTo(140, 3));
      // palette 至少 1 个颜色，且主色也是洋红
      expect(palette, isNotEmpty);
      expect(r255(palette.first), greaterThan(180));
      expect(b255(palette.first), greaterThan(100));
    });

    test('主色占多数时 palette 首项是主色', () {
      final pixels = <List<int>>[
        ..._solid(30, 90, 200, 48), // 蓝：多数
        ..._solid(240, 200, 30, 4), // 黄：少数
      ];
      final res = quantizeCoverColors(_rgba(pixels))!;
      expect(res.$3.first.b, greaterThan(res.$3.first.r));
    });

    test('全黑 / 全白 → 返回 null（保留默认配色，不污染主题）', () {
      expect(quantizeCoverColors(_rgba(_solid(0, 0, 0, 16))), isNull);
      expect(quantizeCoverColors(_rgba(_solid(255, 255, 255, 16))), isNull);
    });

    test('灰色（无饱和）→ c2 回退为 c1 的补色', () {
      final res = quantizeCoverColors(_rgba(_solid(128, 128, 128, 16)))!;
      final (c1, c2, _) = res;
      expect(r255(c1), closeTo(128, 2));
      // 无 sat>24 的像素 → c2 = 255 - c1*0.5 ≈ 191
      expect(r255(c2), closeTo(191, 2));
      expect(r255(c2), greaterThan(r255(c1)));
    });

    test('取色结果确实随封面变化（两张不同封面 → 两组不同主题色）', () {
      final warm = quantizeCoverColors(_rgba(_solid(230, 120, 40, 32)))!;
      final cool = quantizeCoverColors(_rgba(_solid(30, 80, 200, 32)))!;
      expect(warm.$1.r, greaterThan(warm.$1.b)); // 暖色：红 > 蓝
      expect(cool.$1.b, greaterThan(cool.$1.r)); // 冷色：蓝 > 红
    });

    test('palette 最多 5 色', () {
      final pixels = <List<int>>[
        ..._solid(200, 30, 30, 10),
        ..._solid(30, 200, 30, 10),
        ..._solid(30, 30, 200, 10),
        ..._solid(200, 200, 30, 10),
        ..._solid(30, 200, 200, 10),
        ..._solid(200, 30, 200, 10),
        ..._solid(120, 120, 120, 10),
      ];
      final res = quantizeCoverColors(_rgba(pixels))!;
      expect(res.$3.length, lessThanOrEqualTo(5));
    });
  });
}