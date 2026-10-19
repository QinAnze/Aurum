/// 音高散落（非歌词段 / 超长句后半段专用）。
///
/// 与 [PitchBadge] 是**两套互不相干的视觉**，按相位二选一：
///  - 人声段（歌词）：封面中央一个**衬线**字母，从下升起 + 发光
///    —— 见 pitch_badge.dart
///  - 乐器段（>8s 间隙 / 超长句 >8s 的部分）：**整块背景**随机散落的
///    **像素字**，每换一个音就多一个，放满就清空重来
///
/// 两套字体是刻意的：背景是街机/机器的质感（HYPixel），中央是乐谱的质感
/// （EB Garamond），一眼就能分清现在处在哪个状态。
///
/// 落点：整个视口（含顶部），纯随机取点 + 矩形避让。
///
/// 每个字母独立随机的四件事：
///  - **字号**：分三档 —— 小（0.45–0.85 基准）/ 中（1.0–1.9）/ 巨（3.0–5.2）。
///    巨型字是整片背景的视觉锚点，刻意只占少数。
///  - **方向**：约 1/4 竖排（逐字换行），其余横排。
///  - **颜色**：从封面取色板里随机挑，再各自微调亮度。
///  - **入场**：见 [ScatterEntrance]，六种随机，掉下来/翻滚/翻转/放大…
///
/// 相位从散落切回中央时，屏上的字会被**吸向封面中心并缩小消失**
/// （[PitchScatterController.suckTo]），吸完才轮到中央字母出现。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 入场动画的种类，每个字随机抽一个
enum ScatterEntrance {
  /// 从上方加速掉下来
  drop,

  /// 从右侧翻滚着滚进来（整圈旋转）
  roll,

  /// 从下方甩上来（带一点回弹过冲）
  swing,

  /// 像翻牌一样绕水平轴翻开
  flip,

  /// 从很大缩到正常
  zoom,

  /// 从左侧滑进来
  slide,
}

/// 一个字当前的呈现姿态：位移 / 缩放 / 旋转 / 透明度。
///
/// 由 [PitchScatterController.tick] 每帧算好写进来，widget 只读不写。
class ScatterPose {
  double dx = 0;
  double dy = 0;
  double sx = 1;
  double sy = 1;
  double angle = 0;
  double alpha = 1;

  bool get isIdentity =>
      dx == 0 && dy == 0 && sx == 1 && sy == 1 && angle == 0 && alpha == 1;
}

/// 一个已经落位的音高字
class ScatterWord {
  ScatterWord({
    required this.note,
    required this.x,
    required this.y,
    required this.size,
    required this.color,
    required this.width,
    required this.height,
    required this.entrance,
    this.vertical = false,
    this.giant = false,
  });

  /// 原始音名（'C#4'）
  final String note;
  final double x;
  final double y;
  final double size;
  final Color color;

  /// 落位时量出的文本尺寸。渲染时必须用它约束 Text：只给 left/top 的话，
  /// Text 的可用宽度是「视口宽 − x」，靠右的字会被挤成自动换行，
  /// 位置与避让矩形全对不上。
  final double width;
  final double height;

  /// true = 竖排（逐字换行）
  final bool vertical;

  /// true = 巨型档（透明度更低，当背景而不是墙）
  final bool giant;

  /// 入场动画种类
  final ScatterEntrance entrance;

  /// 当前姿态（controller 每帧刷新）
  final ScatterPose pose = ScatterPose();

  /// 入场进度 0..1
  double anim = 0;

  /// 被吸入的延迟（秒）：离中心越远越晚起步，形成"被卷走"的层次
  double suckDelay = 0;

  /// 下落的延迟（秒）：随机错落，别让整屏字齐刷刷一起掉
  double fallDelay = 0;

  /// 下落的旋转量（弧度，带方向）与起始角度
  double fallSpin = 0;
  double fallAngle0 = 0;

  /// 吸入开始时的角度。吸入过程中角度要在它基础上叠加，
  /// 直接用 pose.angle 会每帧累加、字越吸越歪。
  double suckAngle0 = 0;

  /// 被吸入的进度 0..1（null 表示还没开始吸）
  double? suck;

  /// 中心点（世界坐标），吸入时用
  double centerX = 0;
  double centerY = 0;

  /// 实际绘制用的文本：竖排时逐字换行，升号 `#` 跟在前一个音名后
  /// （'C#4' → 'C#\n4'），否则会读成「C / 井号 / 4」三行，中间那个符号很怪。
  String get text =>
      vertical ? PitchScatterController.verticalTextOf(note) : note;
}

class _Rect {
  const _Rect(this.x, this.y, this.w, this.h);
  final double x, y, w, h;

  /// [ox],[oy],[ow],[oh] 是候选矩形（要放的新字）。
  ///
  /// 第二、四个条件必须用 `ow`/`oh`（候选自己的宽高）。这里一度写成了
  /// `ox + w` / `oy + h`（已放置矩形的宽高）—— 候选比已有字**更宽**时，
  /// 判定反而更容易通过，大字就会直接压在小字上。
  bool hits(double ox, double oy, double ow, double oh) =>
      ox < x + w && ox + ow > x && oy < y + h && oy + oh > y;
}

/// 落位难度：巨型字要试更多次才找得到空位
enum _Tier { small, medium, giant }

/// 整屏退场的方式。两种视觉完全不同，不要混用：
///  - [suck] 吸向封面中心（散落 → 中央字母的转场）
///  - [fall] 向下坠落（这一批铺满了，换一批）
enum _Exit { none, suck, fall }

/// 纯数据控制器：由 [VizController] 逐帧驱动，widget 只负责画。
class PitchScatterController {
  /// 已落位的字母（按放置顺序排列，画的时候可以整层重建）
  final List<ScatterWord> words = [];

  /// 字体族：assets/ 里打包的像素字体（见 pubspec.yaml）。
  /// 与中央字母的 `AurumSerif` 是两套。
  static const String fontFamily = 'AurumPixel';

  /// 竖排概率
  static const double verticalChance = 0.26;

  /// 巨型字概率
  static const double giantChance = 0.08;

  /// 铺到多满就清屏重来。
  ///
  /// 这个数**不是**眼睛看到的「满度」：它算的是每个字外接矩形的面积，
  /// 而字形周围大半是空白（一个 'C#6' 的框里墨迹只占四成）。
  /// 0.42 实测对应视觉上七成多满，正好是用户要的「75% 就清」。
  static const double maxCoverage = 0.42;

  /// 字数上限。光看面积不够：同一档面积里如果小字抽得多，能塞进
  /// 一百二三十个碎字，观感比「大字少字」的一轮挤得多。用字数钉住上限。
  static const int maxWords = 100;

  /// 基准字号占短边的比例
  static const double baseRatio = 0.045;

  /// 入场动画时长（秒）
  static const double entranceSec = 0.5;

  /// 被吸走的时长（秒）：每个字各自跑这么久，再叠各自的延迟
  static const double suckSec = 0.5;

  /// 吸入延迟最多推迟多久（秒）
  static const double suckSpread = 0.16;

  /// 铺满清屏时单个字的下落时长（秒）
  static const double fallSec = 0.52;

  /// 铺满清屏时下落出发的错落范围（秒）
  static const double fallSpread = 0.14;

  /// 竖排文本：逐字换行，升号 `#` 并到前一个音名后面（'C#4' → 'C#\n4'）
  static String verticalTextOf(String note) {
    final lines = <String>[];
    for (final ch in note.split('')) {
      if (ch == '#' && lines.isNotEmpty) {
        lines[lines.length - 1] = '${lines.last}#';
      } else {
        lines.add(ch);
      }
    }
    return lines.join('\n');
  }

  final math.Random _rng = math.Random();
  List<_Rect> _placed = [];
  double _coverage = 0;

  /// 本轮（清屏后）已经放过几个字。用它在每一轮开头先立一个巨型字：
  /// 巨型字只占 8% 概率，一轮铺满可能一个都没抽到，背景就平了。
  int _sinceClear = 0;

  /// 退场状态：方式 + 已进行的时长（秒）
  _Exit _exit = _Exit.none;
  double _exitT = 0;
  double _exitTotal = 0;

  /// 本次吸入的单个字时长（秒）。延迟已按 spread 算进每个字的 suckDelay，
  /// 这里只管"飞完要多久"。
  double _suckSecCur = suckSec;

  /// 本次下落的单个字时长（秒）
  double _fallSecCur = fallSec;

  /// 当前取色板（来自封面采样）；空则退回白色
  List<Color> _palette = const [];

  Size _size = Size.zero;

  /// 当前视口（未 layout 过时是 Size.zero）
  Size get viewport => _size;

  bool get isEmpty => words.isEmpty;

  /// 是否正在把字吸向中心（转场专用）
  bool get sucking => _exit == _Exit.suck;

  /// 是否正在整屏退场（吸走或下落）
  bool get exiting => _exit != _Exit.none;

  /// 是否还有字在屏上（含正在被吸的）
  bool get busy => words.isNotEmpty;

  /// 更新取色板（封面色变化时由外部每帧灌一次，不会重建已落位的字）
  void setPalette(List<Color> colors) {
    if (identical(colors, _palette)) return;
    if (colors.length == _palette.length) {
      var same = true;
      for (var i = 0; i < colors.length; i++) {
        if (colors[i] != _palette[i]) {
          same = false;
          break;
        }
      }
      if (same) return;
    }
    _palette = List<Color>.unmodifiable(colors);
  }

  /// 视口尺寸变化（或首帧）时调用
  void layout(Size size) {
    if (size == _size) return;
    _size = size;
  }

  /// 清空（切歌 / 关特效 / 铺满）
  void clear() {
    _exit = _Exit.none;
    _exitT = 0;
    _missStreak = 0;
    if (words.isEmpty) return;
    words.clear();
    _placed = [];
    _coverage = 0;
    _sinceClear = 0;
  }

  /// 把屏上所有字吸向 [target]（通常是封面中心），吸完自动清空。
  ///
  /// 从散落切回中央时用：字先被卷进专辑中心，中央字母随后才出现，
  /// 两段视觉就接上了，不会「背景一空、字母凭空冒出来」。
  ///
  /// [sec] / [spread] 可覆盖默认节奏：铺满清屏时用短的一套，
  /// 好赶紧腾出背景放下一批字。
  void suckTo(Offset target,
      {double sec = suckSec, double spread = suckSpread}) {
    if (words.isEmpty) {
      _exit = _Exit.none;
      return;
    }
    // 离中心最远的距离，用来算各自延迟
    var maxD = 1.0;
    for (final w in words) {
      w.centerX = w.x + w.width / 2;
      w.centerY = w.y + w.height / 2;
      final d = (Offset(w.centerX, w.centerY) - target).distance;
      if (d > maxD) maxD = d;
    }
    for (final w in words) {
      final d = (Offset(w.centerX, w.centerY) - target).distance;
      w.suckDelay = (d / maxD) * spread;
      w.suck = null;
      w.suckAngle0 = w.pose.angle;
    }
    _suckSecCur = sec;
    _exit = _Exit.suck;
    _exitT = 0;
    _exitTotal = spread + sec;
    _target = target;
  }

  /// 铺满清屏：不硬删，整屏的字**向下坠落**（错落出发、自由落体加速、
  /// 边掉边淡出、各自带一点旋转），落完才真的清空。
  ///
  /// 这里刻意不用吸入 —— 吸入是「散落 → 中央字母」的转场语言，
  /// 铺满换批用同一套动作会让人以为又要出中央字母了。
  void fallAway() {
    if (words.isEmpty) return;
    if (_size.isEmpty) {
      clear();
      return;
    }
    for (final w in words) {
      w.fallDelay = _rng.nextDouble() * fallSpread;
      // 旋转方向与幅度随机，整屏才不会像一块板子齐刷刷倒下去
      w.fallSpin =
          (_rng.nextBool() ? 1 : -1) * (0.16 + _rng.nextDouble() * 0.42);
      w.fallAngle0 = w.pose.angle;
      w.suck = null;
    }
    _fallSecCur = fallSec;
    _exit = _Exit.fall;
    _exitT = 0;
    _exitTotal = fallSpread + fallSec;
  }

  Offset _target = Offset.zero;

  /// 每帧推进一次：入场动画 + 吸入动画。
  ///
  /// 字落位之后本体是静态的，只有入场那 0.5s 和被吸走时才有位移，
  /// 所以这里只在必要时改 pose；[dt] 为 0 时什么也不做。
  void tick(double dt) {
    if (words.isEmpty || dt <= 0) return;
    if (_exit != _Exit.none) {
      _exitT += dt;
      if (_exitT >= _exitTotal) {
        clear();
        return;
      }
    }
    for (final w in words) {
      _applyEntrance(w, dt);
      if (_exit == _Exit.suck) {
        _applySuck(w, _exitT);
      } else if (_exit == _Exit.fall) {
        _applyFall(w, _exitT);
      }
    }
  }

  /// 停掉退场（中途切回乐器段时用）：字留在原地，恢复到静止姿态
  void cancelExit() {
    if (_exit == _Exit.none) return;
    _exit = _Exit.none;
    _exitT = 0;
    for (final w in words) {
      w.suck = null;
      w.pose
        ..dx = 0
        ..dy = 0
        ..sx = 1
        ..sy = 1
        ..angle = 0
        ..alpha = 1;
    }
  }

  /* ---------------- 每帧姿态 ---------------- */

  /// 入场：六种随机动画，都收在 [entranceSec] 内，结束后 pose 归位。
  void _applyEntrance(ScatterWord w, double dt) {
    if (w.anim >= 1) return;
    w.anim = math.min(1.0, w.anim + dt / entranceSec);
    final a = w.anim;
    final h = _size.height;
    final wd = _size.width;
    // 缓动
    final outC = _easeOutCubic(a);
    final outBack = _easeOutBack(a);
    final inQuad = a * a;
    final fade = math.min(1.0, a * 4);

    switch (w.entrance) {
      case ScatterEntrance.drop:
        // 从上方加速落下，末尾一点回弹；下落中带轻微摆角
        w.pose
          ..dy = -h * 0.42 * (1 - inQuad)
          ..angle = (1 - a) * 0.18 * math.sin(a * math.pi * 2.5)
          ..alpha = fade;
      case ScatterEntrance.roll:
        // 从右侧滚进来，整圈翻转
        w.pose
          ..dx = wd * 0.32 * (1 - outC)
          ..angle = (1 - outC) * math.pi * 2
          ..alpha = math.min(1.0, a * 5);
      case ScatterEntrance.swing:
        // 从下方甩上来，过冲一点再回落
        w.pose
          ..dy = h * 0.3 * (1 - outBack)
          ..angle = -(1 - outBack) * 0.32
          ..alpha = fade;
      case ScatterEntrance.flip:
        // 绕水平轴翻开：先压成一条线再张开
        w.pose
          ..sy = 0.04 + 0.96 * outBack
          ..alpha = math.min(1.0, a * 3);
      case ScatterEntrance.zoom:
        // 从很大缩到正常
        w.pose
          ..sx = 1 + 2.4 * (1 - outBack)
          ..sy = 1 + 2.4 * (1 - outBack)
          ..alpha = math.min(1.0, a * 2.5);
      case ScatterEntrance.slide:
        // 从左侧滑入
        w.pose
          ..dx = -wd * 0.3 * (1 - outC)
          ..alpha = math.min(1.0, a * 5);
    }
    if (w.anim >= 1) {
      w.pose
        ..dx = 0
        ..dy = 0
        ..sx = 1
        ..sy = 1
        ..angle = 0
        ..alpha = 1;
    }
  }

  /// 吸入：从落位飞向封面中心，同时缩小、淡出、轻轻旋转。
  void _applySuck(ScatterWord w, double t) {
    final local = ((t - w.suckDelay) / _suckSecCur).clamp(0.0, 1.0);
    w.suck = local;
    if (local <= 0) return;
    // 加速被吸走：越靠近中心越快
    final e = local * local;
    w.pose
      ..dx = (_target.dx - w.centerX) * e
      ..dy = (_target.dy - w.centerY) * e
      ..sx = 1 - 0.86 * e
      ..sy = 1 - 0.86 * e
      ..angle = w.suckAngle0 + e * 0.5
      ..alpha = 1 - e;
  }

  /// 下落：自由落体加速掉到屏幕外，边掉边淡出、各自旋转。
  ///
  /// 位移量按每个字自己的 y 算，保证 e=1 时整块字都在视口下方之外
  /// （竖排的高字与巨型字都要照顾到，不能统一用画布高度）。
  void _applyFall(ScatterWord w, double t) {
    final local = ((t - w.fallDelay) / _fallSecCur).clamp(0.0, 1.0);
    if (local <= 0) return;
    final e = local * local; // ease-in quad = 自由落体
    final travel = (_size.height + w.height + 48) - w.y;
    w.pose
      ..dx = e * w.fallSpin * 26
      ..dy = e * travel
      ..angle = w.fallAngle0 + e * w.fallSpin
      ..alpha = 1 - e * e;
  }

  static double _easeOutCubic(double t) {
    final u = 1 - t;
    return 1 - u * u * u;
  }

  static double _easeOutBack(double t) {
    const c1 = 1.70158;
    const c3 = c1 + 1;
    final u = t - 1;
    return 1 + c3 * u * u * u + c1 * u * u;
  }

  /* ---------------- 落位 ---------------- */

  /// 每检测到一个新音高调用一次：[rnd] 外部注入，保证测试可确定性。
  ///
  /// 返回 false 表示这次没放上去。两种 false 要分开看：
  ///  - **铺满了**（面积/字数到顶）→ 清空，下一帧从空屏重来；
  ///  - **只是这个字塞不进缝**（还没满，但它是巨型字）→ 保留已铺好的背景。
  bool spawn(String note, {math.Random? rnd}) {
    final r = rnd ?? _rng;
    final size = _size;
    if (size.isEmpty || note.isEmpty) return false;
    layout(size);
    // 正在被吸走的时候不接受新字：否则会把吸入中的字一起清掉
    if (exiting) return false;
    if (_isFull()) {
      fallAway();
      return false;
    }

    _overflowed = false;
    var tier = _pickTier(r);
    var ok = _tryPlace(note, tier, r);
    // 巨型字挤不进去时降一档再试：宁可这次小一点，也不要空着。
    if (!ok && tier == _Tier.giant) {
      ok = _tryPlace(note, _Tier.medium, r);
    }
    if (ok) {
      _missStreak = 0;
      return true;
    }
    // 放不下有三种：①再加就超面积/字数；②这一批塞不进缝了（连续多次
    // 失败）；③只是这个字太大，缝里放不下。①②要吸走换一批，③保留背景。
    // 只用 `_isFull()` 判会卡在死角：屏上还有零碎缝隙但随机落点撞不上，
    // 既不铺新字也不换批，背景就僵在那里。
    _missStreak++;
    if (_overflowed || _missStreak >= 6 || _isFull()) fallAway();
    return false;
  }

  /// 上一次 [_tryPlace] 是否因为「再加这个字就超面积/字数」而失败
  bool _overflowed = false;

  /// 连续几次 spawn 都塞不进缝。攒够了就当这一批铺满了 ——
  /// 只按面积判会卡在死角：还有 5% 的零碎缝隙，但随机落点怎么都撞不上，
  /// 于是既不铺新字也不换批，背景僵在那一屏。
  int _missStreak = 0;

  /// 是否已经铺满：面积或字数到了上限
  bool _isFull() {
    if (_size.isEmpty) return false;
    if (words.length >= maxWords) return true;
    return _coverage >= _size.width * _size.height * maxCoverage;
  }

  _Tier _pickTier(math.Random r) {
    // 每一轮的头两个字先放巨型字：屏幕空着，一定塞得下，
    // 背景一开始就有锚点，而不是先铺满小字再被大字挤开。
    if (_sinceClear < 2) return _Tier.giant;
    final v = r.nextDouble();
    if (v < giantChance) return _Tier.giant;
    if (v < giantChance + 0.34) return _Tier.medium;
    return _Tier.small;
  }

  /// 按档位抽字号（短边为基准，跟窗口一起缩放）
  ///
  /// 三档之间刻意留断档（0.85 → 1.00、1.90 → 3.00）：连续分布只会得到
  /// 一堆「差不多大」的字，看起来还是均匀。断档才有大小节奏。
  static double _fontSizeFor(_Tier tier, math.Random r, Size size) {
    final base = math.max(10.0, size.shortestSide * baseRatio);
    return switch (tier) {
      _Tier.small => base * (0.45 + r.nextDouble() * 0.40), // 0.45–0.85
      _Tier.medium => base * (1.00 + r.nextDouble() * 0.90), // 1.00–1.90
      _Tier.giant => base * (3.00 + r.nextDouble() * 2.20), // 3.00–5.20
    };
  }

  /// 竖排的字只剩半个宽，同字号看起来比横排小一截 → 补 1.2 倍
  static const double verticalScale = 1.2;

  bool _tryPlace(String note, _Tier tier, math.Random r) {
    final size = _size;
    final vertical = r.nextDouble() < verticalChance;
    final giant = tier == _Tier.giant;
    final fontSize = _fontSizeFor(tier, r, size) *
        (vertical ? verticalScale : 1.0);
    final entrance = ScatterEntrance
        .values[r.nextInt(ScatterEntrance.values.length)];
    final text = vertical ? verticalTextOf(note) : note;
    final (tw, th) = measure(text, fontSize, vertical: vertical);

    if (tw <= 0 || th <= 0) return false;
    if (tw > size.width - 8 || th > size.height - 8) return false;

    // 铺满了就不再塞：清空重来
    final area = size.width * size.height;
    if (words.length >= maxWords || _coverage + tw * th > area * maxCoverage) {
      _overflowed = true;
      return false;
    }

    // 巨型字落位难，多试；小字快速放弃
    final attempts = switch (tier) {
      _Tier.giant => 240,
      _Tier.medium => 90,
      _Tier.small => 50,
    };
    // 边距：像素字的字肩会顶到框边，贴边会被裁掉；字与字之间也留缝。
    const pad = 8.0;
    const margin = 6.0;
    final maxX = math.max(margin, size.width - tw - margin);
    final maxY = math.max(margin, size.height - th - margin);
    for (var i = 0; i < attempts; i++) {
      // 整块背景随机撒：不分区、不分带，顶部与底部机会均等
      final x = margin + r.nextDouble() * (maxX - margin);
      final y = margin + r.nextDouble() * (maxY - margin);
      if (_placed.any(
          (p) => p.hits(x - pad, y - pad, tw + pad * 2, th + pad * 2))) {
        continue;
      }
      _place(note, vertical, giant, entrance, x, y, tw, th, fontSize, r);
      return true;
    }
    return false;
  }

  /// 从封面色板里挑一个：色板为空就白色，否则随机挑并在亮度上抖一点，
  /// 免得一堆同色字糊成一片。巨型字压低一点不透明度，当背景而不是墙。
  Color _pickColor(math.Random r, bool giant) {
    final alpha = giant ? 0.80 : 0.93;
    if (_palette.isEmpty) return Colors.white.withValues(alpha: alpha);
    final hsl = HSLColor.fromColor(_palette[r.nextInt(_palette.length)]);
    final l = (hsl.lightness + 0.10 + r.nextDouble() * 0.24).clamp(0.58, 0.95);
    return hsl.withLightness(l.toDouble()).toColor().withValues(alpha: alpha);
  }

  void _place(
    String note,
    bool vertical,
    bool giant,
    ScatterEntrance entrance,
    double x,
    double y,
    double tw,
    double th,
    double fontSize,
    math.Random r,
  ) {
    final w = ScatterWord(
      note: note,
      x: x,
      y: y,
      size: fontSize,
      color: _pickColor(r, giant),
      width: tw,
      height: th,
      vertical: vertical,
      giant: giant,
      entrance: entrance,
    );
    // 入场从"还没出现"开始：pose 归位由第一帧 tick 推出来
    w.pose.alpha = 0;
    words.add(w);
    _placed.add(_Rect(x, y, tw, th));
    _coverage += tw * th;
    _sinceClear++;
  }

  /// 按屏幕尺寸估一个容量上限（面积控制之外的兜底，测试可读）
  static int computeCapacity(Size size) {
    if (size.isEmpty) return maxWords;
    final base = math.max(10.0, size.shortestSide * baseRatio);
    final cell = base * 1.6;
    final n = (size.width * size.height / (cell * cell)).floor();
    return n.clamp(24, maxWords);
  }

  /// 文本尺寸（用与绘制完全一致的 style，避免落位与实画错位）。
  static (double, double) measure(String text, double fontSize,
      {bool vertical = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: styleFor(fontSize, vertical: vertical),
      ),
      textDirection: TextDirection.ltr,
      maxLines: vertical ? null : 1,
    )..layout();
    return (tp.width, tp.height);
  }

  /// 纯字：**没有 shadows**（用户明确要求去掉发光）。颜色由每个字自己带。
  ///
  /// `inherit: false` 是必须的：默认 true 时会和 Material 的
  /// `DefaultTextStyle` 合并，凭空多出下划线，行高也会变 —— 行高一变，
  /// [measure] 量的框就和实际画的框对不上，避让失效，字开始互相压。
  ///
  /// 像素字体只有一个字重，`fontWeight` 直接忽略（传 bold 会让引擎合成
  /// 假粗体，把像素边糊掉）。
  static TextStyle styleFor(
    double fontSize, {
    Color? color,
    bool vertical = false,
  }) =>
      TextStyle(
        inherit: false,
        fontFamily: fontFamily,
        fontSize: fontSize,
        // 像素字自带很紧的行高，竖排压到 0.9 就够
        height: vertical ? 0.9 : 1.0,
        letterSpacing: vertical ? 0 : -0.01 * fontSize,
        color: color ?? Colors.white.withValues(alpha: 0.93),
        decoration: TextDecoration.none,
      );
}

/// 显示层：把 [PitchScatterController.words] 画满整屏。
class PitchScatter extends StatelessWidget {
  const PitchScatter({super.key, required this.controller});

  final PitchScatterController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.words.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: SizedBox.expand(
        child: Stack(
          children: [
            for (final w in controller.words)
              Positioned(
                left: w.x,
                top: w.y,
                // 显式宽高：不给的话 Text 会按「剩余宽度」自动换行
                width: w.width,
                height: w.height,
                child: _posed(w),
              ),
          ],
        ),
      ),
    );
  }

  /// 把 pose 套到字上：位移 → 旋转 → 缩放 → 透明度
  Widget _posed(ScatterWord w) {
    final p = w.pose;
    Widget child = Text(
      w.text,
      textAlign: TextAlign.center,
      style: PitchScatterController.styleFor(
        w.size,
        color: w.color,
        vertical: w.vertical,
      ),
    );
    if (p.alpha < 0.999) {
      child = Opacity(opacity: p.alpha.clamp(0.0, 1.0), child: child);
    }
    if (p.sx != 1 || p.sy != 1) {
      child = Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(p.sx, p.sy, 1),
        child: child,
      );
    }
    if (p.angle != 0) {
      child = Transform.rotate(angle: p.angle, child: child);
    }
    if (p.dx != 0 || p.dy != 0) {
      child = Transform.translate(offset: Offset(p.dx, p.dy), child: child);
    }
    return child;
  }
}
