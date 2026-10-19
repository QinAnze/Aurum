// Aurum 视觉数据通路的离线自检：不依赖声卡，直接喂合成样本。
//
// 校验三件事：
//  1. FFT 的峰值落在正确的频段（440Hz 正弦 → 低频段，不是随机位置）；
//  2. RMS 与理论值一致（满幅正弦 = 0.707）；
//  3. climax 的门槛语义正确（安静的歌不抖，响的歌段落才起）。
//
// 这三条一旦破了，频谱环和词云就会「看着在动但和音乐没关系」。

#include "AurumVisual.h"
#include "FftTap.h"

#include <cmath>
#include <cstdio>

namespace {
constexpr double kTwoPi = 6.283185307179586;
constexpr int kRate = 44100;

int failures = 0;

void check(bool condition, const char *message) {
    if (!condition) {
        std::printf("FAIL: %s\n", message);
        ++failures;
    }
}

/** 生成 [seconds] 秒、[freq] Hz、幅度 [amplitude] 的正弦，分块喂给 tap */
void feedSine(FftTap &tap, double freq, double seconds, double amplitude) {
    const int total = static_cast<int>(kRate * seconds);
    constexpr int chunk = 512;
    float block[chunk];
    for (int offset = 0; offset < total; offset += chunk) {
        const int count = std::min(chunk, total - offset);
        for (int i = 0; i < count; ++i) {
            const double t = static_cast<double>(offset + i) / kRate;
            block[i] = static_cast<float>(amplitude * std::sin(kTwoPi * freq * t));
        }
        tap.feedMono(block, count);
    }
}

int peakIndex(const std::array<double, AurumVisual::kBins> &values) {
    int best = 0;
    for (int i = 1; i < static_cast<int>(values.size()); ++i) {
        if (values[i] > values[best]) {
            best = i;
        }
    }
    return best;
}
}

int main() {
    // ---- 1. 440Hz 正弦应落在低频段 ----
    {
        FftTap tap;
        feedSine(tap, 440, 0.3, 0.8);
        check(tap.ready(), "tap 应已积累足够样本");

        AurumVisual visual;
        visual.update(tap, true, true);
        const int peak = peakIndex(visual.spectrum());
        std::printf("440Hz → 峰值频段 index=%d\n", peak);
        check(peak >= 2 && peak <= 9, "440Hz 的峰值应落在第 2~9 段（低频）");

        // 高次谐波不应高于基频：峰值必须是全场最大
        double sum = 0;
        for (double v : visual.spectrum()) {
            sum += v;
        }
        check(sum > 1.0, "频谱不应整条为 0");
    }

    // ---- 2. RMS：满幅正弦理论值 0.707 ----
    {
        FftTap tap;
        feedSine(tap, 440, 0.2, 1.0);
        const double rms = tap.rms();
        std::printf("满幅正弦 RMS=%.4f\n", rms);
        check(rms > 0.60 && rms < 0.80, "满幅正弦的 RMS 应接近 0.707");
    }

    // ---- 3. 安静的歌不触发 climax（loudMax < 0.26 门槛）----
    {
        FftTap tap;
        AurumVisual visual;
        feedSine(tap, 300, 0.5, 0.05); // 很轻
        for (int frame = 0; frame < 120; ++frame) {
            visual.update(tap, true, true);
        }
        std::printf("轻微音量 climax=%.4f\n", visual.climax());
        check(visual.climax() < 0.02, "轻音乐不应产生高潮抖动");
    }

    // ---- 4. 响的段落应把 climax 顶起来 ----
    {
        FftTap tap;
        AurumVisual visual;
        // 先来一段安静铺底，再来一段满幅 —— 模拟歌曲进入高潮
        feedSine(tap, 300, 0.2, 0.02);
        for (int frame = 0; frame < 40; ++frame) {
            visual.update(tap, true, true);
        }
        feedSine(tap, 300, 1.0, 0.85);
        for (int frame = 0; frame < 120; ++frame) {
            visual.update(tap, true, true);
        }
        std::printf("响段落 climax=%.4f loudMax=%.4f\n", visual.climax(), visual.loudMax());
        check(visual.climax() > 0.5, "满幅段落的 climax 应明显上升");
        check(visual.loudMax() > 0.3, "loudMax 应记录到本曲最响段落");
    }

    // ---- 5. 静音后频谱要落回去，不能卡在峰值 ----
    {
        FftTap tap;
        AurumVisual visual;
        feedSine(tap, 440, 0.3, 0.8);
        for (int frame = 0; frame < 30; ++frame) {
            visual.update(tap, true, true);
        }
        // 喂 2 秒静音
        static float silence[512] = {};
        for (int i = 0; i < 172; ++i) {
            tap.feedMono(silence, 512);
        }
        for (int frame = 0; frame < 90; ++frame) {
            visual.update(tap, false, true);
        }
        double sum = 0;
        for (double v : visual.spectrum()) {
            sum += v;
        }
        std::printf("静音后频谱总和=%.4f climax=%.4f\n", sum, visual.climax());
        check(sum < 0.6, "静音后频谱应衰减到接近 0");
        check(visual.climax() < 0.05, "暂停后 climax 应回落");
    }

    if (failures == 0) {
        std::printf("Aurum visual checks passed\n");
        return 0;
    }
    std::printf("%d check(s) failed\n", failures);
    return 1;
}
