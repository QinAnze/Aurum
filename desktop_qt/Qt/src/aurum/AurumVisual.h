#pragma once
#include "FftTap.h"
#include <array>

/// Aurum 的可视化状态机：把原始 FFT 幅度与 RMS 变成「可以直接画」的两组量。
///
///  - spectrum：120 个 0~1 的频段值，做了自适应峰值归一化 + gamma 提亮 +
///    非对称平滑（升快落慢），保证任何音源标度都能用满量程；
///  - climax：本曲内相对响度的高潮因子，驱动封面抖动、歌名发光、词云缩放。
///
/// 参数与 `aurum_flutter/lib/effects/viz_controller.dart` 完全一致，
/// 是逐值移植而非重新调参 —— 两边观感要能对上。
class AurumVisual {
  public:
    static constexpr int kBins = FftTap::kBins;

    /// 每帧调用一次。[enabled] 为 false 时（超频总开关关闭）climax 与频谱快速回落。
    /// [tap] 传可变引用：这一帧顺便驱动 FFT 重算（惰性求值，不跟解码帧率绑定）。
    void update(FftTap &tap, bool playing, bool enabled);

    double climax() const { return climax_; }
    const std::array<double, kBins> &spectrum() const { return spectrum_; }
    /// 本曲观测到的最响 RMS（用于调试与「这首歌是不是压满了」的判断）
    double loudMax() const { return loudMax_; }

    void reset();

  private:
    double loudMax_ = 0;
    double climax_ = 0;
    double specPeak_ = 0;
    std::array<double, kBins> spectrum_{};
};
