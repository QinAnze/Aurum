#include "FftTap.h"

#include <QAudioFormat>
#include <algorithm>
#include <cmath>

namespace {
constexpr double kTwoPi = 6.283185307179586;
}

void FftTap::reset() {
    ring_.fill(0);
    data_.fill({});
    bins_.fill(0);
    head_ = 0;
    filled_ = 0;
    energy_ = 0;
    rms_ = 0;
    dirty_ = true;
}

void FftTap::push(double value) {
    if (filled_ == kSize) {
        // 缓冲已满：挤掉最旧的样本，平方和同步扣减
        const double evicted = ring_[head_];
        energy_ -= evicted * evicted;
        if (energy_ < 0) {
            energy_ = 0; // 长跑后的浮点漂移兜底
        }
    } else {
        ++filled_;
    }
    ring_[head_] = value;
    energy_ += value * value;
    head_ = (head_ + 1) % kSize;
    // 写入即更新，渲染侧任何时刻读 rms() 都是当前值，不会晚一帧
    rms_ = filled_ > 0 ? std::sqrt(energy_ / filled_) : 0;
    dirty_ = true;
}

void FftTap::feed(const QAudioBuffer &buffer) {
    if (!buffer.isValid() || buffer.frameCount() <= 0) {
        return;
    }
    const auto format = buffer.format();
    const int channels = std::max(1, format.channelCount());
    const int frames = buffer.frameCount();
    const auto sampleFormat = format.sampleFormat();

    // 逐帧混成单声道；不同采样格式统一换算到 -1..1
    for (int i = 0; i < frames; ++i) {
        double sum = 0;
        for (int c = 0; c < channels; ++c) {
            const int index = i * channels + c;
            double value = 0;
            switch (sampleFormat) {
            case QAudioFormat::Float:
                value = buffer.constData<float>()[index];
                break;
            case QAudioFormat::Int16:
                value = buffer.constData<qint16>()[index] / 32768.0;
                break;
            case QAudioFormat::Int32:
                value = buffer.constData<qint32>()[index] / 2147483648.0;
                break;
            case QAudioFormat::UInt8:
                value = (buffer.constData<quint8>()[index] - 128) / 128.0;
                break;
            default:
                value = 0;
                break;
            }
            sum += value;
        }
        push(sum / channels);
    }
    dirty_ = true;
}

void FftTap::feedMono(const float *samples, int count) {
    if (!samples || count <= 0) {
        return;
    }
    for (int i = 0; i < count; ++i) {
        push(samples[i]);
    }
    dirty_ = true;
}

void FftTap::ensureWindow() {
    if (windowReady_) {
        return;
    }
    // Hann 窗：减少频谱泄漏，避免低幅频段被邻道淹没
    for (int i = 0; i < kSize; ++i) {
        window_[i] = 0.5 * (1 - std::cos(kTwoPi * i / (kSize - 1)));
    }
    windowReady_ = true;
}

const std::array<double, FftTap::kBins> &FftTap::bins() {
    if (dirty_) {
        recompute();
    }
    return bins_;
}

void FftTap::recompute() {
    ensureWindow();
    if (filled_ < kSize / 4) {
        bins_.fill(0);
        rms_ = 0;
        dirty_ = false;
        return;
    }

    // 环形缓冲按时间顺序拷出（最旧 → 最新），不足部分补零
    const int start = (head_ - kSize + kSize * 2) % kSize;
    for (int i = 0; i < kSize; ++i) {
        const double raw = ring_[(start + i) % kSize];
        data_[i] = std::complex<double>(raw * window_[i], 0);
    }

    transform();

    // Aurum 的映射：低频密、高频疏，0.65 只取到有效带宽的前段
    constexpr int fftLength = kSize / 2;
    for (int i = 0; i < kBins; ++i) {
        const double t = static_cast<double>(i) / kBins;
        const int bin = 2 + static_cast<int>(std::pow(t, 1.15) * (fftLength - 4) * 0.65);
        bins_[i] = bin < fftLength ? std::abs(data_[bin]) : 0.0;
    }
    dirty_ = false;
}

void FftTap::transform() {
    // 迭代式 radix-2：位反转置换 + 逐级蝶形
    constexpr int n = kSize;
    for (int i = 1, j = 0; i < n; ++i) {
        int bit = n >> 1;
        for (; j & bit; bit >>= 1) {
            j ^= bit;
        }
        j ^= bit;
        if (i < j) {
            std::swap(data_[i], data_[j]);
        }
    }
    for (int len = 2; len <= n; len <<= 1) {
        const double angle = -kTwoPi / len;
        const std::complex<double> step(std::cos(angle), std::sin(angle));
        for (int i = 0; i < n; i += len) {
            std::complex<double> w(1, 0);
            for (int j = 0; j < len / 2; ++j) {
                const auto even = data_[i + j];
                const auto odd = data_[i + j + len / 2] * w;
                data_[i + j] = even + odd;
                data_[i + j + len / 2] = even - odd;
                w *= step;
            }
        }
    }
}
