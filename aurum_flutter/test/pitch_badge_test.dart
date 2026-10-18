// 音高字母层：从下方升起 / 段落结束向下落 / note 为空时不占位。
import 'package:aurum/effects/pitch_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _rect = Rect.fromLTWH(100, 100, 300, 300);
const _c1 = Color(0xFFC9A06A);

Widget _host(String? note) => MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            PitchBadge(note: note, revision: 1, rect: _rect, c1: _c1),
          ],
        ),
      ),
    );

void main() {
  testWidgets('进场：从下方升到封面中央', (tester) async {
    await tester.pumpWidget(_host('E5'));
    await tester.pump(const Duration(milliseconds: 60));
    final early = tester.getCenter(find.text('E5')).dy;

    await tester.pump(const Duration(milliseconds: 600));
    final settled = tester.getCenter(find.text('E5')).dy;

    expect(early, greaterThan(settled), reason: '升起过程中应当更靠下');
    // 落位后应当在封面矩形中心附近
    expect((settled - _rect.center.dy).abs(), lessThan(2));
  });

  testWidgets('note 变 null：先向下落，动画结束才移除', (tester) async {
    await tester.pumpWidget(_host('E5'));
    await tester.pump(const Duration(milliseconds: 600));

    await tester.pumpWidget(_host(null));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('E5'), findsOneWidget, reason: '坠落过程还在屏幕上');
    final falling = tester.getCenter(find.text('E5')).dy;
    expect(falling, greaterThan(_rect.center.dy));

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
