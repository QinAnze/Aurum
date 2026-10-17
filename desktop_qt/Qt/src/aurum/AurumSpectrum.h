#pragma once
#include <QJsonArray>
#include <array>
#include <functional>

/// Aurum 频谱环绘制助手（移植自 aurum_flutter/lib/effects/spectrum_ring.dart）。
///
/// 设计约束：HUD 是立即模式，所有绘制都通过 `op(QJsonArray)` 追加指令；
/// 频谱环用「相邻点中点二次贝塞尔」闭合曲线，经 `path` 指令描边。
namespace aurum {

/// HUD 指令回调：NativeHud::op 的包装。
using HudOp = std::function<void(const QJsonArray &)>;

/// 频谱环振幅上限（曲线可向外凸起的最大像素），与 Flutter ringAmpMax 一致。
double ringAmpMax(double canvasHalf, double coverWidth);

/// 绘制 360° 环绕封面的实时频谱环。
/// @param cx,cy     封面圆心（HUD 舞台坐标）
/// @param coverWidth 封面边长（曲线基准半径紧贴封面边缘）
/// @param vals      平滑后的 120 段频谱值（0..1）
/// @param climax    高潮因子（0..1），>0 时整圈发散白色辉光
/// @param oc        超频总开关（辉光与加粗的触发条件）
void drawSpectrumRing(HudOp op, double cx, double cy, double coverWidth,
                     const std::array<double, 120> &vals, double climax, bool oc);

} // namespace aurum
