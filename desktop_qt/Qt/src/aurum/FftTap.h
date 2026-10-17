#pragma once
#include <QAudioBuffer>
#include <array>
#include <complex>

/// 音频数据通路：把播放器解码出的 PCM 变成可视化可用的频谱与响度。
///
/// QMediaPlayer（Rhine 的播放内核）本身不暴露波形；Qt 6.8 起可以用
/// `QAudioBufferOutput` 挂上去，每 10~20ms 收到一帧已解码的 PCM。
/// 这里做三件事：
///   1. 多声道混成单声道，写进定长环形缓冲；
///   2. 取最新 2048 点加 Hann 窗，跑一次迭代式 radix-2 FFT；
///   3. 按 Aurum 的对数分 bin 公式映射成 120 个频段（与频谱环点数一致）。
///
/// 只在被询问时重算（dirty 标记），所以帧率由渲染侧决定，不跟解码帧率绑定。
class FftTap {
  public:
    static constexpr int kSize = 2048; // FFT 点数
    static constexpr int kBins = 120;  // 与 Aurum 频谱环点数一致

    /// 送入一帧解码后的 PCM（由 QAudioBufferOutput 直接回调）
    void feed(const QAudioBuffer &buffer);
    /// 直接送入单声道样本（单测用，绕过 QAudioBuffer 的构造）
    void feedMono(const float *samples, int count);
    void reset();

    /// 重算并返回 120 个频段幅度（未归一化，0 起步、量级随曲目而定）
    const std::array<double, kBins> &bins();
    /// 最近一窗的响度 RMS（0~1 量级，按样本满量程归一）
    double rms() const { return rms_; }
    /// 是否已积累到足够的样本（不足时频谱应保持静止）
    bool ready() const { return filled_ >= kSize / 2; }

  private:
    std::array<double, kSize> ring_{};
    std::array<double, kSize> window_{};
    std::array<std::complex<double>, kSize> data_{};
    std::array<double, kBins> bins_{};
    int head_ = 0;   // 下一个写入位置
    int filled_ = 0; // 已写入的有效样本数（上限 kSize）
    double energy_ = 0; // 环形缓冲内样本的平方和（写入时增量维护）
    double rms_ = 0;
    bool windowReady_ = false;
    bool dirty_ = true;

    /// 写入一个样本：同时维护平方和与 RMS，保证 rms() 永远是当前值
    void push(double value);
    void ensureWindow();
    void transform();
    void recompute();
};
