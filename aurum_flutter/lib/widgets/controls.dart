/// Aurum · 播放控件行（对应原版 .controls：三列网格保证播放键与封面圆心同轴）。
/// 左组(模式+上一首, 右对齐) / 播放键(居中) / 右组(下一首+音量, 左对齐)。
library;

import 'package:flutter/material.dart';

import '../models.dart';
import '../theme/tokens.dart';
import 'svg_icon.dart';
import 'volume_knob.dart';

class Controls extends StatelessWidget {
  const Controls({
    super.key,
    required this.mode,
    required this.playing,
    required this.volume,
    required this.muted,
    required this.volAnimToken,
    required this.onTogglePlay,
    required this.onNext,
    required this.onPrev,
    required this.onCycleMode,
    required this.onToggleMute,
    required this.onVolume,
  });

  final PlayMode mode;
  final bool playing;
  final double volume;
  final bool muted;
  final int volAnimToken;
  final VoidCallback onTogglePlay;
  final VoidCallback onNext;
  final VoidCallback onPrev;
  final VoidCallback onCycleMode;
  final VoidCallback onToggleMute;
  final ValueChanged<double> onVolume;

  List<String> get _modePaths => switch (mode) {
        PlayMode.list => AIcon.modeList,
        PlayMode.one => AIcon.modeOne,
        PlayMode.shuffle => AIcon.modeShuffle,
      };

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final gap = clampD(constraints.maxWidth * 0.024, 14, 26);
        return SizedBox(
          width: zoneWidth(constraints.maxWidth),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _CtlButton(
                      tooltip: mode.label,
                      onTap: onCycleMode,
                      child: FlipIcon(
                        paths: _modePaths,
                        iconKey: mode,
                        kind: FlipKind.mode,
                        size: 24,
                        color: kText,
                        strokeWidth: 2,
                      ),
                    ),
                    SizedBox(width: gap),
                    _CtlButton(
                      tooltip: '上一首',
                      onTap: onPrev,
                      child: const AurumIcon(AIcon.prev,
                          size: 27, fill: true, color: kText),
                    ),
                  ],
                ),
              ),
              SizedBox(width: gap),
              _CtlButton(
                tooltip: '播放 / 暂停',
                onTap: onTogglePlay,
                child: FlipIcon(
                  paths: playing ? AIcon.pause : AIcon.play,
                  iconKey: playing,
                  size: 42,
                  fill: true,
                  color: kText,
                ),
              ),
              SizedBox(width: gap),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    _CtlButton(
                      tooltip: '下一首',
                      onTap: onNext,
                      child: const AurumIcon(AIcon.next,
                          size: 27, fill: true, color: kText),
                    ),
                    SizedBox(width: gap),
                    _VolButton(
                      muted: muted,
                      onTap: onToggleMute,
                    ),
                    SizedBox(
                        width: clampD(constraints.maxWidth * 0.01, 2, 10)),
                    VolumeKnob(
                      volume: volume,
                      muted: muted,
                      onChanged: onVolume,
                      animToken: volAnimToken,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

double zoneWidth(double w) => w < kProgressZoneWidth ? w : kProgressZoneWidth;

class _CtlButton extends StatefulWidget {
  const _CtlButton({required this.child, required this.onTap, this.tooltip});

  final Widget child;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  State<_CtlButton> createState() => _CtlButtonState();
}

class _CtlButtonState extends State<_CtlButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: Tooltip(
          message: widget.tooltip ?? '',
          child: AnimatedScale(
            scale: _pressed
                ? kPressScale
                : _hovered
                    ? 1.08
                    : 1,
            duration: const Duration(milliseconds: 120),
            curve: kEaseOut,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _VolButton extends StatelessWidget {
  const _VolButton({required this.muted, required this.onTap});

  final bool muted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _CtlButton(
      tooltip: muted ? '取消静音' : '静音',
      onTap: onTap,
      child: FlipIcon(
        paths: muted ? AIcon.volOff : AIcon.volOn,
        iconKey: muted,
        size: 26,
        color: muted ? kTextDim : kText,
        strokeWidth: 2,
      ),
    );
  }
}
