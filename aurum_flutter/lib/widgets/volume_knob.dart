/// Aurum · 音量旋钮（对应原版 #vol：270° 弧 + 底部缺口，白色弧随音量增减）。
/// 交互：竖向拖拽(±dy/140) / 滚轮(±0.04) / 方向键(±0.05)。
/// 静音切换时弧线以 easeInOutCubic 非线性滑向目标（音频本身即时切换）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/services.dart';

import '../theme/tokens.dart';

class VolumeKnob extends StatefulWidget {
  const VolumeKnob({
    super.key,
    required this.volume,
    required this.muted,
    required this.onChanged,
    this.animToken = 0,
    this.size = 30,
  });

  final double volume;
  final bool muted;
  final ValueChanged<double> onChanged;
  /// 变化即触发一次非线性弧动画（静音/取消静音）；拖动不传新值
  final int animToken;
  final double size;

  @override
  State<VolumeKnob> createState() => _VolumeKnobState();
}

class _VolumeKnobState extends State<VolumeKnob>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: kVolBarMs),
  );
  double _display = 1;
  double _dragStartY = 0;
  double _dragStartV = 0;

  @override
  void initState() {
    super.initState();
    _display = widget.volume;
  }

  @override
  void didUpdateWidget(VolumeKnob old) {
    super.didUpdateWidget(old);
    if (old.volume != widget.volume || old.muted != widget.muted) {
      if (old.animToken != widget.animToken) {
        // 非线性滑动（两端缓、中段快）
        final from = _display;
        final to = widget.volume;
        _c.forward(from: 0);
        _c.removeListener(_arcListener);
        _arcFrom = from;
        _arcTo = to;
        _c.addListener(_arcListener);
      } else {
        _display = widget.volume;
      }
    }
  }

  double _arcFrom = 0, _arcTo = 0;
  void _arcListener() {
    final e = Curves.easeInOutCubic.transform(_c.value);
    setState(() => _display = _arcFrom + (_arcTo - _arcFrom) * e);
  }

  @override
  void dispose() {
    _c.removeListener(_arcListener);
    _c.dispose();
    super.dispose();
  }

  void _nudge(double delta) {
    widget.onChanged((widget.volume + delta).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
              event.logicalKey == LogicalKeyboardKey.arrowRight) {
            _nudge(0.05);
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
              event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _nudge(-0.05);
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: Listener(
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) {
            _nudge(-event.scrollDelta.dy.sign * 0.04);
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (d) {
            _dragStartY = d.globalPosition.dy;
            _dragStartV = widget.volume;
          },
          onVerticalDragUpdate: (d) {
            widget.onChanged(
                (_dragStartV + (_dragStartY - d.globalPosition.dy) / 140)
                    .clamp(0.0, 1.0));
          },
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: CustomPaint(
              painter: _KnobPainter(
                value: _display.clamp(0.0, 1.0),
                muted: widget.muted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _KnobPainter extends CustomPainter {
  const _KnobPainter({required this.value, required this.muted});

  final double value;
  final bool muted;

  @override
  void paint(Canvas canvas, Size size) {
    // viewBox 44×44，r=17，stroke-width=3（270° 弧，底部 90° 为几何缺口）
    final s = size.width / 44;
    final r = 17 * s;
    final sw = 3 * s;
    final center = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: center, radius: r);
    const start = math.pi * 0.75; // 135° 左下
    const sweep = math.pi * 1.5; // 270°

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = sw
      ..strokeCap = StrokeCap.round
      ..color = const Color(0x29FFFFFF);
    canvas.drawArc(rect, start, sweep, false, track);

    final val = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = sw
      ..strokeCap = StrokeCap.round
      ..color = muted ? const Color(0x66FFFFFF) : kPureWhite;
    canvas.drawArc(rect, start, sweep * value, false, val);
  }

  @override
  bool shouldRepaint(_KnobPainter old) =>
      old.value != value || old.muted != muted;
}
