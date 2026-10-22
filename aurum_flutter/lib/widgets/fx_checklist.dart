/// Aurum · 逐特效开关（折叠式）。
///
/// 收起时只占一个小胶囊（「特效 3/4」+ 箭头），和顶栏其他控件同一行；
/// 展开后从胶囊下方浮出一块面板，里面四类特效各一个方框、互不干扰。
///
/// 为什么用浮层而不是直接把面板撑开：展开成竖排会把顶栏顶高，
/// 左侧「打开列表」按钮被挤到垂直居中，两边就不在同一高度了。
/// 浮层不动布局，顶栏高度恒定。
///
/// 总开关关着的时候整块变暗，但依然可点 —— 点一下会把总开关顺手打开
/// （见 AppState.toggleFxItem）。
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

class FxChecklist extends StatefulWidget {
  const FxChecklist({
    super.key,
    required this.items,
    required this.masterOn,
    required this.onToggle,
    this.c1 = kDefaultC1,
    this.c2 = kDefaultC2,
    this.initiallyOpen = false,
  });

  final List<FxItem> items;
  /// 总开关状态：关着时整块降透明度（仍可点）
  final bool masterOn;
  final ValueChanged<String> onToggle;
  final Color c1;
  final Color c2;
  /// 首帧是否展开（测试/调试用，正常是收起的）
  final bool initiallyOpen;

  @override
  State<FxChecklist> createState() => _FxChecklistState();
}

class _FxChecklistState extends State<FxChecklist> {
  final OverlayPortalController _portal = OverlayPortalController();
  bool _open = false;

  /// 胶囊高度：和顶栏里「打开列表」那个方按钮（44）同一中线对齐，
  /// 具体对齐由顶栏那行 Row 的 crossAxisAlignment.center 保证。
  static const double kChipH = 32;

  @override
  void initState() {
    super.initState();
    _open = widget.initiallyOpen;
    if (_open) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _portal.show();
      });
    }
  }

  @override
  void dispose() {
    if (_portal.isShowing) _portal.hide();
    super.dispose();
  }

  void _setOpen(bool v) {
    if (v == _open) return;
    setState(() => _open = v);
    if (v) {
      _portal.show();
    } else {
      _portal.hide();
    }
  }

  @override
  Widget build(BuildContext context) {
    final onCount = widget.items.where((i) => i.value).length;
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (_) => _overlay(),
      child: _chip(onCount),
    );
  }

  /* ---------------- 收起态：一枚胶囊 ---------------- */

  Widget _chip(int onCount) {
    return GestureDetector(
      key: const ValueKey('fx-chip'),
      behavior: HitTestBehavior.opaque,
      onTap: () => _setOpen(!_open),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedOpacity(
          opacity: widget.masterOn ? 1 : 0.55,
          duration: const Duration(milliseconds: 200),
          curve: kEaseOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: kEaseOut,
            height: kChipH,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _open ? const Color(0x3DFFFFFF) : const Color(0x1FFFFFFF),
              ),
              color: _open ? const Color(0x14FFFFFF) : const Color(0x0FFFFFFF),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '特效',
                  style: fontStyle(
                    size: 11.5,
                    weight: FontWeight.w500,
                    color: widget.masterOn ? kTextDim : kTextFaint,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  '$onCount/${widget.items.length}',
                  style: fontStyle(
                    size: 10.5,
                    weight: FontWeight.w600,
                    color: widget.masterOn ? kText : kTextFaint,
                  ),
                ),
                const SizedBox(width: 2),
                AnimatedRotation(
                  turns: _open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 180),
                  curve: kEaseOut,
                  child: const Icon(
                    Icons.expand_more,
                    size: 15,
                    color: kTextDim,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /* ---------------- 展开态：浮层 ---------------- */

  Widget _overlay() {
    // 位置自己算（不用 CompositedTransformFollower）：follower 依赖合成层
    // 的 leader 变换，离屏截图/测试里拿不到，面板会画不出来。
    final box = context.findRenderObject() as RenderBox?;
    var left = 0.0;
    var top = 0.0;
    if (box != null && box.hasSize) {
      final origin = box.localToGlobal(Offset.zero);
      left = origin.dx + box.size.width - _kPanelW;
      top = origin.dy + box.size.height + 6;
    }
    return Stack(
      children: [
        // 点空白处收起
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _setOpen(false),
          ),
        ),
        Positioned(
          left: left,
          top: top,
          child: _DropIn(child: _panel()),
        ),
      ],
    );
  }

  static const double _kPanelW = 104;

  Widget _panel() {
    return AnimatedOpacity(
      opacity: widget.masterOn ? 1 : 0.55,
      duration: const Duration(milliseconds: 200),
      curve: kEaseOut,
      child: Container(
        key: const ValueKey('fx-panel'),
        width: _kPanelW,
        padding: const EdgeInsets.fromLTRB(9, 5, 9, 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0x24FFFFFF)),
          // 浮层要不透明，否则底下的歌名会透上来糊成一片
          color: const Color(0xF2141720),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 22,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < widget.items.length; i++) ...[
              if (i > 0) const SizedBox(height: 5),
              _Box(
                item: widget.items[i],
                // 总开关关着时方框一律显示为未勾选（它确实没在跑）
                checked: widget.masterOn && widget.items[i].value,
                c1: widget.c1,
                c2: widget.c2,
                onTap: () => widget.onToggle(widget.items[i].key),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 浮层入场：淡入 + 轻微上移。
///
/// 必须自己拿 AnimationController —— 外面 HomePage 每帧都在重建
/// （viz 的 ticker 常驻），用 TweenAnimationBuilder 会被每帧重置回 0，
/// 面板就永远停在「全透明」上（widget 在树里，但看不见）。
class _DropIn extends StatefulWidget {
  const _DropIn({required this.child});

  final Widget child;

  @override
  State<_DropIn> createState() => _DropInState();
}

class _DropInState extends State<_DropIn> {
  bool _in = false;

  @override
  void initState() {
    super.initState();
    // 用隐式动画（AnimatedOpacity/AnimatedSlide）而不是 AnimationController：
    // 控制器在 overlay 重建时容易被重置到 0，面板就永远全透明。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _in = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _in ? 1 : 0,
      duration: const Duration(milliseconds: 150),
      curve: kEaseOut,
      child: AnimatedSlide(
        offset: Offset(0, _in ? 0 : -0.06),
        duration: const Duration(milliseconds: 150),
        curve: kEaseOut,
        child: widget.child,
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
