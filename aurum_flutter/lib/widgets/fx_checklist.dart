/// Aurum · 逐特效复选框（排在总开关下面）。
///
/// 四类特效各一个方框，互不干扰；总开关关着的时候整排变暗，
/// 但依然可点 —— 点一下会把总开关顺手打开（见 AppState.toggleFxItem）。
library;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// 一项特效：键名 + 中文标签
class FxItem {
  const FxItem({
    required this.key,
    required this.label,
    required this.value,
  });

  final String key;
  final String label;
  final bool value;
}

class FxChecklist extends StatelessWidget {
  const FxChecklist({
    super.key,
    required this.items,
    required this.masterOn,
    required this.onToggle,
    this.c1 = kDefaultC1,
    this.c2 = kDefaultC2,
  });

  final List<FxItem> items;
  /// 总开关状态：关着时整排降透明度（仍可点）
  final bool masterOn;
  final ValueChanged<String> onToggle;
  final Color c1;
  final Color c2;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: masterOn ? 1 : 0.45,
      duration: const Duration(milliseconds: 200),
      curve: kEaseOut,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: const Color(0x1FFFFFFF)),
          color: const Color(0x0FFFFFFF),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) const SizedBox(height: 5),
              _Box(
                item: items[i],
                // 总开关关着时方框一律显示为未勾选（它确实没在跑）
                checked: masterOn && items[i].value,
                c1: c1,
                c2: c2,
                onTap: () => onToggle(items[i].key),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Box extends StatefulWidget {
  const _Box({
    required this.item,
    required this.checked,
    required this.onTap,
    required this.c1,
    required this.c2,
  });

  final FxItem item;
  final bool checked;
  final VoidCallback onTap;
  final Color c1;
  final Color c2;

  @override
  State<_Box> createState() => _BoxState();
}

class _BoxState extends State<_Box> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.checked;
    return GestureDetector(
      key: ValueKey('fx-check-${widget.item.key}'),
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? kPressScale : 1,
        duration: const Duration(milliseconds: 110),
        curve: kEaseOut,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: kEaseOut,
                width: 13,
                height: 13,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3.5),
                  border: Border.all(
                    color: on ? const Color(0x00000000) : const Color(0x5CFFFFFF),
                  ),
                  gradient: on
                      ? LinearGradient(colors: [widget.c1, widget.c2])
                      : null,
                ),
                child: on
                    ? const Icon(
                        Icons.check,
                        size: 10,
                        color: Color(0xF2070A12),
                      )
                    : null,
              ),
              const SizedBox(width: 6),
              Text(
                widget.item.label,
                style: fontStyle(
                  size: 11.5,
                  weight: FontWeight.w500,
                  color: on ? kTextDim : kTextFaint,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
