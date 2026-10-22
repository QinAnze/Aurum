// 音高字母层：从下方升起 / 段落结束向下落 / note 为空时不占位。
import 'package:aurum/effects/pitch_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _rect = Rect.fromLTWH(100, 100, 300, 300);
/// 落位点相对封面圆心的上移量：字号 = 0.22 边长，再上移 0.52 字高
const double _lift = 300 * 0.22 * 0.52;
const _c1 = Color(0xFFC9A06A);

Widget _host(String? note,
        {double glow = 0, double blur = 0, double scale = 1}) =>
    MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            PitchBadge(
              note: note,
              revision: 1,
              rect: _rect,
              c1: _c1,
              glow: glow,
              blur: blur,
              scale: scale,
            ),
          ],
        ),
      ),
    );

/// 取当前字形实际用的 TextStyle
TextStyle _styleOf(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style!;

/// 当前树里最大的 X 轴缩放（PitchBadge 用 Transform.scale 放大，不改布局尺寸）
double _maxScale(WidgetTester tester) {
  var m = 0.0;
  for (final t in tester.widgetList<Transform>(find.byType(Transform))) {
    final s = t.transform.storage[0];
    if (s > m) m = s;
  }
  return m;
}

void main() {
  testWidgets('发光与放大：climax 越高，光晕越大、字越大', (tester) async {
    await tester.pumpWidget(_host('E5'));
    await tester.pump(const Duration(milliseconds: 600));
    final calm = _styleOf(tester, 'E5');
    final calmScale = _maxScale(tester);

    await tester.pumpWidget(_host('E5', glow: 1, blur: 24, scale: 1.35));
    await tester.pump(const Duration(milliseconds: 600));
    final hot = _styleOf(tester, 'E5');
    final hotScale = _maxScale(tester);

    expect(calm.shadows, isNotNull, reason: '常亮也有一层基础光晕');
    expect(hot.shadows!.length, greaterThan(calm.shadows!.length),
        reason: '高潮应当多一层大光斑');
    final calmMax = calm.shadows!
        .map((s) => s.blurRadius)
        .reduce((a, b) => a > b ? a : b);
    final hotMax =
        hot.shadows!.map((s) => s.blurRadius).reduce((a, b) => a > b ? a : b);
    expect(hotMax, greaterThan(calmMax), reason: '光晕半径要跟着变大');

    // 放大：走 Transform.scale（不改布局尺寸，所以查矩阵）
    expect(calmScale, closeTo(1.0, 0.02));
    expect(hotScale, closeTo(1.35, 0.02), reason: '高潮时字要变大');
  });

  testWidgets('进场：从下方升到圆心偏上（让位给直线频谱）', (tester) async {
    await tester.pumpWidget(_host('E5'));
    await tester.pump(const Duration(milliseconds: 60));
    final early = tester.getCenter(find.text('E5')).dy;

    await tester.pump(const Duration(milliseconds: 600));
    final settled = tester.getCenter(find.text('E5')).dy;

    expect(early, greaterThan(settled), reason: '升起过程中应当更靠下');
    // 落位点在圆心上方半个字高，且仍在封面圆内
    final expectY = _rect.center.dy - _lift;
    expect((settled - expectY).abs(), lessThan(2));
    expect(settled, lessThan(_rect.center.dy), reason: '必须高于圆心');
  });

  testWidgets('note 变 null：先向下落，动画结束才移除', (tester) async {
    await tester.pumpWidget(_host('E5'));
    await tester.pump(const Duration(milliseconds: 600));
    final settled = tester.getCenter(find.text('E5')).dy;

    await tester.pumpWidget(_host(null));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('E5'), findsOneWidget, reason: '坠落过程还在屏幕上');
    final falling = tester.getCenter(find.text('E5')).dy;
    expect(falling, greaterThan(settled), reason: '要往下掉');

    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('E5'), findsNothing);
  });

  testWidgets('换音：新音重新升起（段内换音）', (tester) async {
    await tester.pumpWidget(_host('E5'));
    await tester.pump(const Duration(milliseconds: 600));

    await tester.pumpWidget(_host('G5'));
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.text('G5'), findsOneWidget);
    expect(find.text('E5'), findsNothing, reason: '旧字直接替换，不叠影');
    final early = tester.getCenter(find.text('G5')).dy;
    await tester.pump(const Duration(milliseconds: 400));
    final settled = tester.getCenter(find.text('G5')).dy;
    expect(early, greaterThan(settled));
  });

  testWidgets('没有封面矩形 / 没有音名：不占位', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              const PitchBadge(note: 'E5', revision: 1, rect: null, c1: _c1),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('E5'), findsNothing);
  });
}
