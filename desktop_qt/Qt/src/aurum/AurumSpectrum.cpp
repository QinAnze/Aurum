#include "AurumSpectrum.h"
#include <QString>
#include <cmath>

namespace aurum {

double ringAmpMax(double canvasHalf, double coverWidth) {
    return std::max(canvasHalf * 0.12, canvasHalf * 0.92 - coverWidth / 2 * 1.02);
}

void drawSpectrumRing(HudOp op, double cx, double cy, double coverWidth,
                     const std::array<double, 120> &vals, double climax, bool oc) {
    constexpr int N = 120;
    const double baseR = coverWidth / 2 * 1.02;
    const double canvasHalf = coverWidth * 0.92; // 画布 ≈ 封面 1.84×，留出环凸起空间
    const double ampMax = ringAmpMax(canvasHalf, coverWidth);

    // 120 个角度均分点，半径随频谱起伏
    double px[120], py[120];
    const double step = 6.283185307179586 / N;
    for (int i = 0; i < N; ++i) {
        const double ang = i * step - 1.5707963267948966; // 从正上方开始顺时针
        const double r = baseR + vals[i] * ampMax * (1 + climax * 0.35);
        px[i] = cx + std::cos(ang) * r;
        py[i] = cy + std::sin(ang) * r;
    }

    // 经相邻点中点的二次贝塞尔 → 平滑闭合环
    auto n = [](double v) { return QString::number(v, 'f', 2); };
    QString path;
    const int last = N - 1;
    double mx = (px[last] + px[0]) / 2;
    double my = (py[last] + py[0]) / 2;
    path += "M " + n(mx) + " " + n(my);
    for (int i = 0; i < N; ++i) {
        const double curx = px[i], cury = py[i];
        const int nx = (i + 1) % N;
        const double mx2 = (curx + px[nx]) / 2;
        const double my2 = (cury + py[nx]) / 2;
        path += " Q " + n(curx) + " " + n(cury) + " " + n(mx2) + " " + n(my2);
    }
    path += " Z";

    const double strokeW = 2 + (oc ? climax * 1.6 : 0.0);
    const double alpha = (0.6 + (oc ? climax * 0.4 : 0.0));
    const double aClamped = std::min(1.0, std::max(0.0, alpha));
    const double glowAlpha = std::min(1.0, 0.62 * climax);

    /* 高潮时整条曲线发散白色辉光。Glyphs 的 path 指令不支持模糊，
       用「先铺一圈更粗、更低透明的描边，再叠清晰主线」近似发光。 */
    if (oc && climax > 0.02) {
        op(QJsonArray{"path", path, strokeW + climax * 3.5,
                      QJsonArray{1, 1, 1, glowAlpha / 2}, QJsonArray{}, 0});
        op(QJsonArray{"path", path, strokeW + climax * 2.0,
                      QJsonArray{1, 1, 1, glowAlpha}, QJsonArray{}, 0});
    }

    // 清晰主线（覆盖在辉光之上，任何 climax 下线条都锐利可见）
    op(QJsonArray{"path", path, strokeW, QJsonArray{1, 1, 1, aClamped}, QJsonArray{}, 0});
}

} // namespace aurum
