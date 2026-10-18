// 打光层渲染测试：level=0 不能画任何东西（否则会糊住整个窗口），
// level=1 时边缘有光、画面中心保持透明。
//
// 注意：picture.toImage 是平台侧异步任务，在 widget test 的假时钟里永远不会完成，
// 必须包在 tester.runAsync 里跑（否则整个测试挂死）。
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:aurum/effects/edge_light.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const int w = 400;
const int h = 300;

Future<ByteData> _render(double level) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  EdgeLightPainter(
    level: level,
    c1: const Color(0xFFFFCC66),
    c2: const Color(0xFF66CCFF),
  ).paint(canvas, const Size(400, 300));
  final picture = recorder.endRecording();
  final image = await picture.toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  picture.dispose();
  return data!;
}

int _alphaAt(ByteData data, int x, int y) =>
    data.getUint8((y * w + x) * 4 + 3);

void main() {
  testWidgets('EdgeLight：0 全透明，1 边缘亮中心透明', (tester) async {
    final off = (await tester.runAsync(() => _render(0)))!;
    var anyAlpha = false;
    for (var i = 3; i < off.lengthInBytes; i += 4) {
      if (off.getUint8(i) != 0) {
        anyAlpha = true;
        break;
      }
    }
    expect(anyAlpha, isFalse, reason: 'level=0 必须完全透明，不能挡画面');

    final on = (await tester.runAsync(() => _render(1)))!;
    expect(_alphaAt(on, 2, 2), greaterThan(0), reason: '左上角应被灯带照亮');
    expect(_alphaAt(on, w - 3, 2), greaterThan(0));
    expect(_alphaAt(on, 2, h - 3), greaterThan(0));
    expect(_alphaAt(on, w ~/ 2, h ~/ 2), 0, reason: '中心必须保持干净');
  });
}
