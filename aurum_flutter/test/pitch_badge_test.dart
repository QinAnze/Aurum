// 音高字母层：有音名时显示在封面矩形中心，null 时不占位。
import 'package:aurum/effects/pitch_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('PitchBadge：显示音名 / note 为空时隐藏', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              PitchBadge(
                note: 'E5',
                revision: 1,
                rect: const Rect.fromLTWH(100, 100, 300, 300),
                c1: const Color(0xFFC9A06A),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('E5'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              PitchBadge(
                note: null,
                revision: 1,
                rect: const Rect.fromLTWH(100, 100, 300, 300),
                c1: const Color(0xFFC9A06A),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('E5'), findsNothing);
  });
}
