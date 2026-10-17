/// Aurum · 视觉特效总开关（对应原版 #masterToggle：词云/频谱/超频 合一）。
/// 玻璃 pill + track/knob + ON/OFF 标签。
library;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class MasterToggle extends StatefulWidget {
  const MasterToggle({
    super.key,
    required this.on,
    required this.onChanged,
    this.c1 = kDefaultC1,
    this.c2 = kDefaultC2,
  });

  final bool on;
  final ValueChanged<bool> onChanged;
  final Color c1;
  final Color c2;

  @override
  State<MasterToggle> createState() => _MasterToggleState();
}

class _MasterToggleState extends State<MasterToggle> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: () => widget.onChanged(!widget.on),
      child: AnimatedScale(
        scale: _pressed ? kPressScale : 1,
        duration: const Duration(milliseconds: 120),
        curve: kEaseOut,
        child: Container(
          padding: const EdgeInsets.fromLTRB(7, 6, 12, 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(99),
            border: Border.all(color: const Color(0x29FFFFFF)),
            color: const Color(0x14FFFFFF),
            boxShadow: [
              BoxShadow(
                color: const Color(0x47FFFFFF),
                offset: const Offset(0, 1),
                blurRadius: 0,
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // track 30×17
              Container(
                width: 30,
                height: 17,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(99),
                  gradient: widget.on
                      ? LinearGradient(
                          colors: [widget.c1, widget.c2],
                        )
                      : null,
                  color: widget.on ? null : const Color(0x24FFFFFF),
                ),
                child: Align(
                  alignment:
                      widget.on ? Alignment.centerRight : Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Container(
                      width: 13,
                      height: 13,
                      decoration: const BoxDecoration(
                        color: Color(0xD9FFFFFF),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Color(0x59000000),
                            blurRadius: 4,
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                widget.on ? 'ON' : 'OFF',
                style: fontStyle(
                  size: 12.5,
                  weight: FontWeight.w600,
                  color: widget.on ? kText : kTextDim,
                ).copyWith(letterSpacing: 1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
