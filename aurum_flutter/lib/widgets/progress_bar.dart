/// Aurum · 进度条（对应原版 .progress-zone：Pointer 拖拽 1:1 跟踪，松手才 seek）。
/// 纯白填充 + 白色微光；hover/拖拽时轨道变粗、旋钮浮现。
library;

import 'package:flutter/material.dart';

import '../models.dart' show fmtTime;
import '../theme/tokens.dart';

class ProgressBar extends StatefulWidget {
  const ProgressBar({
    super.key,
    required this.position,
    required this.duration,
    required this.dragging,
    required this.dragRatio,
    required this.onBeginDrag,
    required this.onUpdateDrag,
    required this.onEndDrag,
  });

  final double position;
  final double duration;
  final bool dragging;
  final double dragRatio;
  final ValueChanged<double> onBeginDrag;
  final ValueChanged<double> onUpdateDrag;
  final VoidCallback onEndDrag;

  @override
  State<ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<ProgressBar> {
  bool _hovered = false;

  /// 目标进度（引擎每 200ms 推送一次位置）
  double get _targetRatio {
    if (widget.duration <= 0) return 0;
    return (widget.position / widget.duration).clamp(0.0, 1.0);
  }

  double _ratioOf(BoxConstraints c, double dx) =>
      (dx / c.maxWidth).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    // 引擎每秒只推 5 次位置，直接用它画条就是「每 200ms 跳一格」；
    // 原版由 RAF 逐帧驱动，条是连续爬的。这里用 240ms 线性补间把跨度补满，
    // 视觉上等价于逐帧推进。拖拽必须 1:1 跟手，不做补间。
    if (widget.dragging) return _buildContent(widget.dragRatio);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: _targetRatio),
      duration: const Duration(milliseconds: 240),
      curve: Curves.linear,
      builder: (_, ratio, __) => _buildContent(ratio),
    );
  }

  Widget _buildContent(double ratio) {
    final cur = ratio * widget.duration;
    return SizedBox(
      width: double.infinity,
      child: Column(
        children: [
          MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final thick =
                    _hovered || widget.dragging ? 9.0 : 6.0;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) {
                    if (widget.duration <= 0) return;
                    widget.onBeginDrag(_ratioOf(constraints, d.localPosition.dx));
                  },
                  onTapUp: (_) => widget.onEndDrag(),
                  onPanStart: (d) {
                    if (widget.duration <= 0) return;
                    widget.onBeginDrag(_ratioOf(constraints, d.localPosition.dx));
                  },
                  onPanUpdate: (d) {
                    widget.onUpdateDrag(
                        _ratioOf(constraints, d.localPosition.dx));
                  },
                  onPanEnd: (_) => widget.onEndDrag(),
                  onPanCancel: () => widget.onEndDrag(),
                  child: SizedBox(
                    height: 22,
                    child: Stack(
                      alignment: Alignment.centerLeft,
                      children: [
                        // rail
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          curve: kEaseOut,
                          height: thick,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(99),
                            color: const Color(0x24FFFFFF),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.25),
                                offset: const Offset(0, 1),
                                blurRadius: 2,
                              ),
                            ],
                          ),
                        ),
                        // fill（纯白 + 微光）
                        FractionallySizedBox(
                          widthFactor: ratio,
                          child: Container(
                            height: thick,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(99),
                              color: kPureWhite,
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0x80FFFFFF),
                                  blurRadius: 12,
                                ),
                              ],
                            ),
                          ),
                        ),
                        // knob
                        Positioned(
                          left: ratio * constraints.maxWidth - 7.5,
                          child: AnimatedOpacity(
                            opacity:
                                (_hovered || widget.dragging) ? 1 : 0,
                            duration: const Duration(milliseconds: 160),
                            child: AnimatedScale(
                              scale: widget.dragging ? 1.25 : 1,
                              duration: const Duration(milliseconds: 200),
                              curve: kEaseOut,
                              child: Container(
                                width: 15,
                                height: 15,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: kPureWhite,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.45),
                                      blurRadius: 10,
                                      offset: const Offset(0, 2),
                                    ),
                                    BoxShadow(
                                      color: const Color(0x24FFFFFF),
                                      blurRadius: 0,
                                      spreadRadius: 4,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 2),
          // 时间
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(fmtTime(cur),
                  style: fontStyle(
                      size: 11.5,
                      weight: FontWeight.w600,
                      color: kTextFaint)),
              Text(fmtTime(widget.duration),
                  style: fontStyle(
                      size: 11.5,
                      weight: FontWeight.w600,
                      color: kTextFaint)),
            ],
          ),
        ],
      ),
    );
  }
}

