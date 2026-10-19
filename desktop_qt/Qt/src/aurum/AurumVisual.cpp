#include "AurumVisual.h"

#include <algorithm>
#include <cmath>

void AurumVisual::reset() {
    loudMax_ = 0;
    climax_ = 0;
    specPeak_ = 0;
    spectrum_.fill(0);
}

void AurumVisual::update(FftTap &tap, bool playing, bool enabled) {
    const double rms = tap.ready() ? tap.rms() : 0.0;

    // ---- climax：本曲内响度位置 → smoothstep → 起快落慢 ----
    if (rms > loudMax_) {
        loudMax_ = rms; // 捕获全曲最响的持续响度
    } else {
        loudMax_ = std::max(rms, loudMax_ * 0.9997); // 极慢回落
    }
    double position = rms / (loudMax_ + 0.001);
    double c = std::clamp((position - 0.72) / 0.28, 0.0, 1.0);
    c = c * c * (3 - 2 * c); // smoothstep
    if (loudMax_ < 0.26) {
        c = 0; // 门槛：本曲必须出现过真正响的段落，安静的歌不抖
    }
    climax_ += (c - climax_) * (c > climax_ ? 0.34 : 0.06);
    if (!playing) {
        climax_ *= 0.92;
    }
    if (!enabled) {
        climax_ *= 0.85;
    }

    // ---- 频谱：自适应峰值归一 + gamma + 非对称平滑 ----
    const auto &magnitudes = tap.bins();
    double peak = 0;
    for (int i = 0; i < kBins; ++i) {
        if (magnitudes[i] > peak) {
            peak = magnitudes[i];
        }
    }
    // 峰值缓慢回落，避免爆点过后长期压扁整条曲线
    if (peak > specPeak_) {
        specPeak_ = peak;
    } else {
        specPeak_ = std::max(peak, specPeak_ * 0.9995);
    }
    const double inverse = specPeak_ > 1e-9 ? 1.0 / specPeak_ : 0.0;
    for (int i = 0; i < kBins; ++i) {
        const double norm = magnitudes[i] * inverse;
        const double target =
            norm <= 0 ? 0.0 : std::min(1.0, std::pow(norm, 0.55) * 1.15);
        spectrum_[i] += (target - spectrum_[i]) * (target > spectrum_[i] ? 0.82 : 0.20);
    }
}
