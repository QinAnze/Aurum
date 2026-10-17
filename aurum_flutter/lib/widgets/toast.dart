/// Aurum · Toast（对应原版 .toast：底部居中玻璃 pill，2400ms 自动收起）。
library;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class Toast extends StatelessWidget {
  const Toast({super.key, required this.message, required this.visible});

  final String? message;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    final msg = message ?? '';
    return Positioned(
      left: 0,
      right: 0,
      bottom: 30,
      child: Center(
        child: IgnorePointer(
          child: AnimatedSlide(
            offset: visible ? Offset.zero : const Offset(0, 0.6),
            duration: const Duration(milliseconds: 280),
            curve: kEaseOut,
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: const Duration(milliseconds: 220),
              curve: kEaseOut,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: kToastBg,
                  border: Border.all(color: const Color(0x2EFFFFFF)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.45),
                      blurRadius: 40,
                      offset: const Offset(0, 14),
                    ),
                    BoxShadow(
                      color: const Color(0x47FFFFFF),
                      offset: const Offset(0, 1),
                      blurRadius: 0,
                    ),
                  ],
                ),
                child: Text(
                  msg,
                  style: fontStyle(size: 13, weight: FontWeight.w500),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
