/// Aurum · 迷你 SVG 路径解析器 + 图标集。
/// 只实现本项目用到的命令子集（M/m L/l H/h V/v A/a Z/z + 隐式重复），
/// 用来 1:1 复刻原版 index.html 里的 Feather 风格线性图标。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 解析 SVG path data（支持 M m L l H h V v A a Z z，弧用 Flutter 原生 arcToPoint）
Path parseSvgPath(String d) {
  final p = _SvgPathParser(d);
  return p.parse();
}

class _SvgPathParser {
  _SvgPathParser(this._s);
  final String _s;
  int _i = 0;
  final Path _path = Path();
  double _cx = 0, _cy = 0; // 当前点
  double _sx = 0, _sy = 0; // 子路径起点
  String _prev = '';

  Path parse() {
    while (true) {
      _skipSpaces();
      if (_i >= _s.length) break;
      var c = _s[_i];
      if (_isCmd(c)) {
        _i++;
      } else {
        // 隐式重复：M 之后按 L 处理，其余重复上一命令
        c = _prev == 'M'
            ? 'L'
            : _prev == 'm'
                ? 'l'
                : _prev;
        if (c.isEmpty) throw FormatException('bad path: $_s');
      }
      _prev = c;
      switch (c) {
        case 'M':
          _moveTo(_num(), _num(), false);
        case 'm':
          _moveTo(_num(), _num(), true);
        case 'L':
          _lineTo(_num(), _num(), false);
        case 'l':
          _lineTo(_num(), _num(), true);
        case 'H':
          _cx = _num();
          _path.lineTo(_cx, _cy);
        case 'h':
          _cx += _num();
          _path.lineTo(_cx, _cy);
        case 'V':
          _cy = _num();
          _path.lineTo(_cx, _cy);
        case 'v':
          _cy += _num();
          _path.lineTo(_cx, _cy);
        case 'A':
          _arc(_num(), _num(), _num(), _flag(), _flag(), _num(), _num(), false);
        case 'a':
          _arc(_num(), _num(), _num(), _flag(), _flag(), _num(), _num(), true);
        case 'Z':
        case 'z':
          _path.close();
          _cx = _sx;
          _cy = _sy;
        default:
          throw FormatException('unsupported cmd $c in $_s');
      }
    }
    return _path;
  }

  void _moveTo(double x, double y, bool rel) {
    if (rel) {
      _cx += x;
      _cy += y;
    } else {
      _cx = x;
      _cy = y;
    }
    _sx = _cx;
    _sy = _cy;
    _path.moveTo(_cx, _cy);
  }

  void _lineTo(double x, double y, bool rel) {
    if (rel) {
      _cx += x;
      _cy += y;
    } else {
      _cx = x;
      _cy = y;
    }
    _path.lineTo(_cx, _cy);
  }

  void _arc(double rx, double ry, double rot, bool largeArc, bool sweep,
      double x, double y, bool rel) {
    final ex = rel ? _cx + x : x;
    final ey = rel ? _cy + y : y;
    _path.arcToPoint(
      Offset(ex, ey),
      radius: Radius.elliptical(rx.abs(), ry.abs()),
      rotation: rot * math.pi / 180,
      largeArc: largeArc,
      clockwise: sweep,
    );
    _cx = ex;
    _cy = ey;
  }

  /* ---------------- 词法 ---------------- */
  bool _isCmd(String c) =>
      'MmLlHhVvAaZz'.contains(c) && c.isNotEmpty;

  void _skipSpaces() {
    while (_i < _s.length) {
      final c = _s[_i];
      if (c == ' ' || c == ',' || c == '\n' || c == '\t' || c == '\r') {
        _i++;
      } else {
        break;
      }
    }
  }

  double _num() {
    _skipSpaces();
    final start = _i;
    if (_i < _s.length && (_s[_i] == '-' || _s[_i] == '+')) _i++;
    while (_i < _s.length && '0123456789.'.contains(_s[_i])) {
      _i++;
    }
    if (_i < _s.length && (_s[_i] == 'e' || _s[_i] == 'E')) {
      _i++;
      if (_i < _s.length && (_s[_i] == '-' || _s[_i] == '+')) _i++;
      while (_i < _s.length && '0123456789'.contains(_s[_i])) {
        _i++;
      }
    }
    if (_i == start) throw FormatException('expected number at $_i in $_s');
    return double.parse(_s.substring(start, _i));
  }

  bool _flag() {
    _skipSpaces();
    if (_i >= _s.length) throw FormatException('expected flag in $_s');
    final c = _s[_i];
    if (c == '0' || c == '1') {
      _i++;
      return c == '1';
    }
    throw FormatException('expected flag at $_i in $_s');
  }
}

/* ================================================================
   图标集（路径数据与原版 index.html 的 ICON 表一致）
   ================================================================ */
class AIcon {
  AIcon._();

  static const play = ['M8 5v14l11-7z'];
  static const pause = ['M6 5h4v14H6zm8 0h4v14h-4z'];

  /// 列表循环（Feather repeat）
  static const modeList = [
    'M17 2l4 4-4 4',
    'M3 11v-1a4 4 0 0 1 4-4h14',
    'M7 22l-4-4 4-4',
    'M21 13v1a4 4 0 0 1-4 4H3',
  ];

  /// 单曲循环 = 列表循环 + 居中「1」
  static const modeOne = [
    ...modeList,
    'M12 9 V15',
    'M12 9 L10.4 10.6',
  ];

  /// 随机播放
  static const modeShuffle = [
    'M16 3h5v5',
    'M4 20 21 3',
    'M21 16v5h-5',
    'M15 15l6 6',
    'M4 4l5 5',
  ];

  /// 上一首（左向双三角 + 竖线）
  static const prev = ['M15.41 7.41 14 6l-6 6 6 6 1.41-1.41L10.83 12z'];

  /// 下一首
  static const next = ['M8.59 16.59 10 18l6-6-6-6-1.41 1.41L13.17 12z'];

  /// 音量开（喇叭 + 声波）
  static const volOn = [
    'M11 5 6 9H3v6h3l5 4z',
    'M15.5 8.5a5 5 0 0 1 0 7',
    'M18.5 6a9 9 0 0 1 0 12',
  ];

  /// 音量关（喇叭 + X）
  static const volOff = [
    'M11 5 6 9H3v6h3l5 4z',
    'M16 9l5 6',
    'M21 9l-5 6',
  ];

  /// 搜索放大镜（圆 = 两段 180° 弧拼整圆）
  static const search = [
    'M4 11 A7 7 0 1 1 18 11 A7 7 0 1 1 4 11 Z',
    'M20 20 L16.5 16.5',
  ];

  /// 清除 ×
  static const clear = ['M6 6l12 12M18 6L6 18'];

  /// 文件夹（打开）：主体梯形 + 上方标签
  static const folder = [
    'M2 7 A2 2 0 0 1 5 6 H8 L10 8 H19 A2 2 0 0 1 21 9 V18 A2 2 0 0 1 19 19 H5 A2 2 0 0 1 2 18 Z',
  ];

  /// 汉堡菜单
  static const menu = ['M4 7h16M4 12h16M4 17h10'];

  /// 窗口控制
  static const winMin = ['M1 5h8'];
  static const winMax = ['M1.5 4.5h7v7h-7z'];
  static const winClose = ['M1.5 1.5L8.5 8.5M8.5 1.5L1.5 8.5'];
}

final Map<String, Path> _pathCache = {};

Path _cachedPath(List<String> ds) {
  final key = ds.join('|');
  return _pathCache.putIfAbsent(key, () {
    final p = Path();
    for (final d in ds) {
      p.addPath(parseSvgPath(d), Offset.zero);
    }
    return p;
  });
}

/// 线性/填充图标（24×24 viewBox 语义）
class AurumIcon extends StatelessWidget {
  const AurumIcon(
    this.paths, {
    super.key,
    this.size = 24,
    this.color,
    this.strokeWidth = 2,
    this.fill = false,
  });

  final List<String> paths;
  final double size;
  final Color? color;
  final double strokeWidth;
  final bool fill;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _IconPainter(
          path: _cachedPath(paths),
          color: color ?? const Color(0xEBFFFFFF),
          strokeWidth: strokeWidth,
          fill: fill,
        ),
      ),
    );
  }
}

class _IconPainter extends CustomPainter {
  const _IconPainter({
    required this.path,
    required this.color,
    required this.strokeWidth,
    required this.fill,
  });

  final Path path;
  final Color color;
  final double strokeWidth;
  final bool fill;

  @override
  void paint(Canvas canvas, Size size) {
    // 24×24 viewBox → 目标尺寸
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s, s);
    final paint = Paint()
      ..color = color
      ..style = fill ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_IconPainter old) =>
      old.color != color ||
      old.strokeWidth != strokeWidth ||
      old.fill != fill;
}

/* ================================================================
   图标翻转入场（对应原版 iconFlip / modeFlip 关键帧）
   ================================================================ */

/// 关键帧插值：stops = [(t, value)...]
double _keyFrame(double t, List<(double, double)> stops) {
  if (t <= stops.first.$1) return stops.first.$2;
  for (var i = 1; i < stops.length; i++) {
    if (t <= stops[i].$1) {
      final (t0, v0) = stops[i - 1];
      final (t1, v1) = stops[i];
      final k = (t - t0) / (t1 - t0);
      return v0 + (v1 - v0) * k;
    }
  }
  return stops.last.$2;
}

const List<(double, double)> _kFlipRot = [(0, -75), (0.55, 9), (1, 0)];
const List<(double, double)> _kFlipScale = [(0, 0.2), (0.55, 1.22), (1, 1)];
const List<(double, double)> _kFlipAlpha = [(0, 0), (0.55, 1), (1, 1)];
const List<(double, double)> _kModeRot = [(0, -115), (0.55, 12), (1, 0)];
const List<(double, double)> _kModeScale = [(0, 0.3), (0.55, 1.2), (1, 1)];

enum FlipKind { icon, mode }

/// 图标变化时重播翻转入场动画（对应原版 iconFlip：强制回流重启动画）
class FlipIcon extends StatefulWidget {
  const FlipIcon({
    super.key,
    required this.paths,
    required this.iconKey,
    this.size = 24,
    this.color,
    this.strokeWidth = 2,
    this.fill = false,
    this.kind = FlipKind.icon,
  });

  final List<String> paths;
  /// 图标身份：变化即重播动画
  final Object iconKey;
  final double size;
  final Color? color;
  final double strokeWidth;
  final bool fill;
  final FlipKind kind;

  @override
  State<FlipIcon> createState() => _FlipIconState();
}

class _FlipIconState extends State<FlipIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Duration(
        milliseconds:
            widget.kind == FlipKind.mode ? 420 : 380),
  );

  @override
  void initState() {
    super.initState();
    _c.forward();
  }

  @override
  void didUpdateWidget(FlipIcon old) {
    super.didUpdateWidget(old);
    if (old.iconKey != widget.iconKey) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) {
        final t = _c.value;
        if (t >= 1) return child!;
        final rotStops = widget.kind == FlipKind.mode ? _kModeRot : _kFlipRot;
        final scaleStops =
            widget.kind == FlipKind.mode ? _kModeScale : _kFlipScale;
        final alpha = _keyFrame(t, _kFlipAlpha);
        return Opacity(
          opacity: alpha.clamp(0.0, 1.0),
          child: Transform.rotate(
            angle: _keyFrame(t, rotStops) * math.pi / 180,
            alignment: Alignment.center,
            child: Transform.scale(
              scale: _keyFrame(t, scaleStops),
              alignment: Alignment.center,
              child: child,
            ),
          ),
        );
      },
      child: AurumIcon(
        widget.paths,
        size: widget.size,
        color: widget.color,
        strokeWidth: widget.strokeWidth,
        fill: widget.fill,
      ),
    );
  }
}
