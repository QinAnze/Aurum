/// Aurum · 封面组（对应原版 .cover-wrap 内部结构）。
/// 组成：呼吸光晕 + 360° 频谱环 + 圆形黑胶封面（播放时旋转）；
/// 整体绑定高潮抖动；切歌时旧封面先掉落、新封面后飞入（严格先后不重叠）。
library;


import 'package:flutter/material.dart';

import '../effects/spectrum_ring.dart';
import '../effects/viz_controller.dart';
import '../net_image.dart';
import '../theme/tokens.dart';

class CoverArt extends StatefulWidget {
  const CoverArt({
    super.key,
    required this.url,
    required this.spinning,
    required this.viz,
    required this.c1,
    required this.size,
  });

  final String? url;
  final bool spinning;
  final VizController viz;
  final Color c1;
  final double size;

  @override
  State<CoverArt> createState() => _CoverArtState();
}

class _CoverArtState extends State<CoverArt>
    with TickerProviderStateMixin {
  String? _shownUrl;
  String? _ghostUrl;
  String _phase = 'idle'; // idle | fall | rise | pop

  late final AnimationController _fall = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: kCoverFallMs),
    value: 1,
  );
  late final AnimationController _rise = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: kCoverRiseMs),
    value: 1,
  );
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: kCoverPopMs),
    value: 1,
  );
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 16),
  );
  late final AnimationController _breathe = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 7),
  )..repeat(reverse: true);
  Animation<double> get _breatheAnim =>
      CurvedAnimation(parent: _breathe, curve: Curves.easeInOut);

  @override
  void initState() {
    super.initState();
    _shownUrl = widget.url;
    if (widget.url != null) {
      _phase = 'pop';
      _pop.forward(from: 0).then((_) {
        if (mounted) setState(() => _phase = 'idle');
      });
    }
    if (widget.spinning) _spin.repeat();
  }

  @override
  void didUpdateWidget(CoverArt old) {
    super.didUpdateWidget(old);
    if (old.spinning != widget.spinning) {
      if (widget.spinning) {
        _spin.repeat();
      } else {
        _spin.stop(); // 暂停保留角度，不跳变
      }
    }
    if (widget.url != _shownUrl) {
      _swapCover(widget.url);
    }
  }

  void _swapCover(String? url) {
    final hadCover = _shownUrl != null;

    // 新歌没有封面：让旧封面掉下去，然后回到 idle —— 实封面会显示占位图。
    // （这里必须走完动画并把 _phase 复位，否则会永远卡在 fall：
    //   实封面被透明度 0 隐藏、幽灵又已消失 → 封面区变空白。）
    if (url == null) {
      if (!hadCover) {
        setState(() => _phase = 'idle');
        return;
      }
      setState(() {
        _ghostUrl = _shownUrl;
        _shownUrl = null;
        _phase = 'fall';
      });
      _fall.forward(from: 0).then((_) {
        if (!mounted) return;
        setState(() {
          _ghostUrl = null;
          _phase = 'idle';
        });
      });
      return;
    }

    final first = !hadCover;
    setState(() {
      _ghostUrl = _shownUrl;
      _shownUrl = url;
      _phase = first ? 'pop' : 'fall';
    });
    if (first) {
      _pop.forward(from: 0).then((_) {
        if (mounted) setState(() => _phase = 'idle');
      });
      return;
    }
    // 预加载新封面；加载完成后旧封面才掉落（对应原版 img.onload 时序）
    precacheImage(aurumImage(url), context).then((_) {
      if (!mounted) return;
      _fall.forward(from: 0).then((_) {
        if (!mounted) return;
        setState(() => _phase = 'rise');
        _rise.forward(from: 0).then((_) {
          if (!mounted) return;
          setState(() {
            _ghostUrl = null;
            _phase = 'idle';
          });
        });
      });
    }).catchError((_) {
      // 加载失败：直接显示新封面
      if (!mounted) return;
      setState(() {
        _ghostUrl = null;
        _phase = 'idle';
      });
    });
  }

  @override
  void dispose() {
    _fall.dispose();
    _rise.dispose();
    _pop.dispose();
    _spin.dispose();
    _breathe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 回填封面全局矩形（词云封面圆禁区）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final box = context.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        widget.viz.setCoverRect(box.localToGlobal(Offset.zero) & box.size);
      }
    });

    final size = widget.size;
    return AnimatedBuilder(
      animation: widget.viz,
      builder: (context, _) {
        return Transform.translate(
          offset: Offset(widget.viz.shakeDx, widget.viz.shakeDy),
          child: Transform.rotate(
            angle: widget.viz.shakeRot * 3.141592653589793 / 180,
            alignment: Alignment.center,
            child: SizedBox(
              width: size,
              height: size,
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none, // 环画布 1.6×封面，不能裁
                children: [
                  _halo(size),
                  if (widget.viz.spectrumEnabled()) _ring(size),
                  _coverStack(size),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /* ---------------- 光晕（呼吸） ---------------- */
  Widget _halo(double size) {
    final halo = Container(
      width: size * 1.28,
      height: size * 1.28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: const Alignment(0, -0.2),
          colors: [
            widget.c1.withValues(alpha: 0.6),
            Colors.transparent,
          ],
          stops: const [0, 0.68],
        ),
      ),
    );
    // 同 _ring：Stack(loose) 会把光晕压回封面尺寸，须用 OverflowBox 放行
    return OverflowBox(
      alignment: Alignment.center,
      maxWidth: size * 1.28,
      maxHeight: size * 1.28,
      child: AnimatedBuilder(
        animation: _breatheAnim,
        builder: (_, child) => Opacity(
          opacity: 0.8 + 0.2 * _breatheAnim.value,
          child: Transform.scale(
            scale: 0.96 + 0.08 * _breatheAnim.value,
            child: child,
          ),
        ),
        child: halo,
      ),
    );
  }

  /* ---------------- 频谱环 ---------------- */
  Widget _ring(double size) {
    final d = size * 1.6; // inset -30% → 160%
    return AnimatedBuilder(
      animation: widget.viz,
      // Stack 默认 StackFit.loose 会把子件压到 Stack 自身尺寸（= 封面边长），
      // 环画布因此只剩 100% → baseR > 画布半径 → ampMax 为负 → 整圈不画。
      // OverflowBox 让画布拿回真实的 160% 尺寸，并允许其溢出封面范围绘制。
      builder: (_, __) => OverflowBox(
        alignment: Alignment.center,
        maxWidth: d,
        maxHeight: d,
        child: SizedBox(
          width: d,
          height: d,
          child: CustomPaint(
            painter: SpectrumRingPainter(
              vals: widget.viz.specVals,
              climax: widget.viz.climax,
              oc: widget.viz.spectrumEnabled(),
              coverWidth: size,
            ),
          ),
        ),
      ),
    );
  }

  /* ---------------- 封面（旋转 + 切歌动画） ---------------- */
  Widget _coverStack(double size) {
    return Stack(
      alignment: Alignment.center,
      children: [
        if (_ghostUrl != null && _phase == 'fall')
          Positioned.fill(child: _ghostImage(_ghostUrl!)),
        _realCover(size),
      ],
    );
  }

  Widget _imageBox(String? url) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0x0FFFFFFF),
        border: Border.all(color: const Color(0x29FFFFFF)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 70,
            offset: const Offset(0, 34),
          ),
        ],
      ),
      child: ClipOval(
        child: url != null
            ? Image(
                image: aurumImage(url),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const ColoredBox(
                  color: Color(0xFF22283A),
                ),
              )
            : const ColoredBox(color: Color(0xFF22283A)),
      ),
    );
  }

  Widget _realCover(double size) {
    Widget child = SizedBox(
      width: size,
      height: size,
      child: _imageBox(_shownUrl),
    );
    // 旋转（播放时转、暂停时停，保留角度）
    child = AnimatedBuilder(
      animation: _spin,
      builder: (_, c) =>
          Transform.rotate(angle: _spin.value * 6.283185307179586, child: c),
      child: child,
    );
    if (_phase == 'rise') {
      child = AnimatedBuilder(
        animation: _rise,
        builder: (_, c) {
          final t = Curves.easeOutQuint.transform(_rise.value);
          return Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, 92 * (1 - t)),
              child: Transform.scale(scale: 0.86 + 0.14 * t, child: c),
            ),
          );
        },
        child: child,
      );
    } else if (_phase == 'pop') {
      child = AnimatedBuilder(
        animation: _pop,
        builder: (_, c) {
          final t = kCoverPop.transform(_pop.value);
          return Opacity(
            opacity: 0.3 + 0.7 * t,
            child: Transform.scale(scale: 0.88 + 0.12 * t, child: c),
          );
        },
        child: child,
      );
    } else if (_phase == 'fall') {
      // 过渡期隐藏实封面，只让幽灵掉落，避免两张图重叠
      child = Opacity(opacity: 0, child: child);
    }
    return child;
  }

  Widget _ghostImage(String url) {
    return AnimatedBuilder(
      animation: _fall,
      builder: (_, child) {
        final t = kCoverFall.transform(_fall.value);
        return Opacity(
          opacity: 1 - t,
          child: Transform.translate(
            offset: Offset(0, 96 * t),
            child: Transform.rotate(
              angle: 10 * t * 3.141592653589793 / 180,
              alignment: Alignment.center,
              child: Transform.scale(scale: 1 - 0.14 * t, child: child),
            ),
          ),
        );
      },
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: _imageBox(url),
      ),
    );
  }
}
