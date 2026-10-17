/// Aurum · 设计 Token（对齐原版 index.html 的 CSS 变量与动画曲线）。
/// 全局唯一样式来源：色彩 / 字体 / 缓动 / 玻璃材质。
library;

import 'package:flutter/material.dart';

/* ---------------- 字体 ---------------- */
const String kFontFamily = 'SmileySans'; // 得意黑（自带斜体，不二次合成）

TextStyle fontStyle({
  double? size,
  FontWeight? weight,
  Color? color,
  double? letterSpacing,
  double? height,
  List<Shadow>? shadows,
}) {
  return TextStyle(
    fontFamily: kFontFamily,
    fontSize: size,
    fontWeight: weight,
    color: color,
    letterSpacing: letterSpacing,
    height: height,
    shadows: shadows,
  );
}

/* ---------------- 色彩 ---------------- */

/// 默认主题色（播放前）：香槟金 / 灰绿（播放后由封面取色覆盖）
const Color kDefaultC1 = Color(0xFFC9A06A);
const Color kDefaultC2 = Color(0xFF7FA693);

/// 品牌金（logo / 品牌标题）
const Color kBrandGold = Color(0xFFE3C16F);
const Color kBrandTitle = Color(0xFFF3E0A3);

/// 文本三级（白 .92 / .55 / .34）
const Color kText = Color(0xEBFFFFFF);
const Color kTextDim = Color(0x8CFFFFFF);
const Color kTextFaint = Color(0x57FFFFFF);

/// 玻璃材质
const List<double> kGlassGradientStops = [0.0, 1.0];
const List<Color> kGlassGradientColors = [
  Color(0x24FFFFFF), // rgba(255,255,255,.14)
  Color(0x0DFFFFFF), // rgba(255,255,255,.05)
];
const Color kGlassBorder = Color(0x38FFFFFF); // rgba(255,255,255,.22)
const Color kGlassHighlight = Color(0x47FFFFFF); // inset 0 1px 0 rgba(255,255,255,.28)

/// 侧栏结构层（更重的材质）
const List<Color> kSidebarGradientColors = [
  Color(0x5712141E), // rgba(18,20,30,.34)
  Color(0x420C0D16), // rgba(12,13,22,.26)
];

/// 进度条 / 控件纯白
const Color kPureWhite = Color(0xFFFFFFFF);

/// 底色（无封面时的深色底，替代原版透明窗口透出桌面的效果）
const List<Color> kBaseGradient = [
  Color(0xFF0B0D14),
  Color(0xFF10131F),
  Color(0xFF0B0D14),
];

/// Toast
const Color kToastBg = Color(0xB7181A28); // rgba(24,26,40,.72)

/* ---------------- 缓动（对应 CSS cubic-bezier） ---------------- */
const Cubic kEaseOut = Cubic(0.23, 1, 0.32, 1);
const Cubic kEaseInOut = Cubic(0.77, 0, 0.175, 1);
const Cubic kEaseDrawer = Cubic(0.32, 0.72, 0, 1);
const Cubic kCoverPop = Cubic(0.34, 1.56, 0.64, 1); // = Curves.easeOutBack
const Cubic kCoverFall = Cubic(0.5, 0, 0.75, 0); // 重力加速 ease-in
const Cubic kCoverRise = Cubic(0.22, 1, 0.36, 1); // = Curves.easeOutQuint
const double kPressScale = 0.94;

/* ---------------- 时长（ms） ---------------- */
const int kBgFadeMs = 1100; // 背景交叉淡化
const int kCoverFallMs = 580;
const int kCoverRiseMs = 620;
const int kCoverPopMs = 550;
const int kToastMs = 2400;
const int kRowStaggerMs = 30; // 列表 30ms stagger 入场
const int kRowStaggerMaxMs = 420;
const int kVolBarMs = 300; // 音量弧非线性滑动
const int kIconFlipMs = 380; // 播放/暂停图标翻转
const int kModeFlipMs = 420;
const int kVolIconFlipMs = 300;

/* ---------------- 尺寸 ---------------- */
const double kSidebarWidth = 340;
const double kMobileBreakpoint = 880;
const double kGlassRadius = 28;
const double kProgressZoneWidth = 560;

/// 封面尺寸：min(360, 46vw, 44dvh)
double coverSize(BuildContext context) {
  final w = MediaQuery.sizeOf(context).width;
  final h = MediaQuery.sizeOf(context).height;
  final mobile = w < kMobileBreakpoint;
  final base = mobile ? 320.0 : 360.0;
  final vw = mobile ? 0.82 : 0.46;
  final vh = mobile ? 0.40 : 0.44;
  return mathMin(base, mathMin(w * vw, h * vh));
}

double mathMin(double a, double b) => a < b ? a : b;

/* ---------------- 响应式内边距 ---------------- */
EdgeInsets appPadding(BuildContext context) {
  final w = MediaQuery.sizeOf(context).width;
  if (w < kMobileBreakpoint) return const EdgeInsets.all(12);
  return const EdgeInsets.all(20);
}

EdgeInsets playerPadding(BuildContext context) {
  final w = MediaQuery.sizeOf(context).width;
  final h = MediaQuery.sizeOf(context).height;
  final v = clampD(clampD(h * 0.035, 18, 40), 18, 40);
  final hz = clampD(clampD(w * 0.04, 18, 56), 18, 56);
  return EdgeInsets.only(
    top: v,
    left: hz,
    right: hz,
    bottom: clampD(h * 0.03, 16, 30),
  );
}

double clampD(double v, double min, double max) =>
    v < min ? min : (v > max ? max : v);
