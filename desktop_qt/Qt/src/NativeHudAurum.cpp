#include "NativeHud.h"
#include "aurum/AurumSpectrum.h"
#include <cmath>

/* ================================================================
   Aurum 融合（Phase 4）
   左：Rhine 光盘盒（CD 套 + 露出的黑胶碟）
   右：Aurum 竖屏播放器（封面旋转 + 频谱环 + 歌名发光 + 进度 + 控件）
   整窗：词云图层
   ================================================================ */

namespace {
/// 圆角矩形路径（与 NativeHudPlayer 同款，独立一份避免跨文件依赖）。
QString aurumRounded(double x, double y, double w, double h, double r) {
    r = std::max(0.0, std::min(r, std::min(w, h) / 2));
    const auto n = [](double v) { return QString::number(v, 'f', 2); };
    const double x2 = x + w, y2 = y + h;
    QString p = "M " + n(x + r) + " " + n(y);
    p += " L " + n(x2 - r) + " " + n(y);
    p += " Q " + n(x2) + " " + n(y) + " " + n(x2) + " " + n(y + r);
    p += " L " + n(x2) + " " + n(y2 - r);
    p += " Q " + n(x2) + " " + n(y2) + " " + n(x2 - r) + " " + n(y2);
    p += " L " + n(x + r) + " " + n(y2);
    p += " Q " + n(x) + " " + n(y2) + " " + n(x) + " " + n(y2 - r);
    p += " L " + n(x) + " " + n(y + r);
    p += " Q " + n(x) + " " + n(y) + " " + n(x + r) + " " + n(y);
    return p + " Z";
}
/// 实心三角（prev/next）
QString aurumTriangle(double cx, double cy, double s, bool forward) {
    const auto n = [](double v) { return QString::number(v, 'f', 2); };
    const double h = s / 2;
    if (forward) {
        return "M " + n(cx - h * 0.7) + " " + n(cy - h) + " L " + n(cx + h * 0.8) + " " + n(cy) +
               " L " + n(cx - h * 0.7) + " " + n(cy + h) + " Z";
    }
    return "M " + n(cx + h * 0.7) + " " + n(cy - h) + " L " + n(cx - h * 0.8) + " " + n(cy) +
           " L " + n(cx + h * 0.7) + " " + n(cy + h) + " Z";
}
}

/* ---------------- 左：Rhine 光盘盒（CD 套 + 露出的黑胶碟） ---------------- */
void NativeHud::aurumDetailLeft(double x, double y, double width, double height) {
    const auto &player = m_music->player;
    const auto item = m_music->current;
    const QJsonArray accent{119.0 / 255, 123.0 / 255, 96.0 / 255, 1};
    auto glass = ink();
    glass[3] = dark ? 0.10 : 0.62;
    auto line = ink();
    line[3] = dark ? 0.16 : 0.10;

    // CD 套（方形封套，Rhine 风格的圆角方盒）
    const double sleeve = std::min(width, height) * 0.62;
    const double sx = x + (width - sleeve) / 2;
    const double sy = y + height * 0.10;
    op({"fill-path", aurumRounded(sx, sy, sleeve, sleeve, 22), glass});
    op({"path", aurumRounded(sx + 0.5, sy + 0.5, sleeve - 1, sleeve - 1, 21.5), 1, line, QJsonArray{}, 0});
    if (!player.coverImage.isEmpty()) {
        op({"image", player.coverImage, sx + 16, sy + 16, sleeve - 32, sleeve - 32});
    }

    // 露出的黑胶碟：从套右侧滑出，略下移，旋转
    const double discR = sleeve * 0.66;
    const double dx = sx + sleeve - discR * 0.35;
    const double dy = sy + sleeve * 0.55;
    save();
    translate(dx, dy);
    rotate(m_coverAngle * 0.4); // 碟随封面慢转
    translate(-dx, -dy);
    if (!player.coverImage.isEmpty()) {
        op({"image-circle", player.coverImage, dx - discR, dy - discR, discR * 2});
    } else {
        op({"ellipse", glass, dx - discR, dy - discR, discR * 2, discR * 2});
    }
    restore();
    // 唱片中心孔 + 高光环
    auto hole = ink();
    hole[3] = dark ? 0.4 : 0.25;
    op({"ellipse", hole, dx - 9, dy - 9, 18, 18});
    op({"arc", dx, dy, discR - 1, 0, 6.2832, 1.5, line});

    // 标题（叠在盒下方）
    auto title = item["title"].toString();
    if (title.isEmpty()) {
        title = "尚未播放";
    }
    limited(title, x, sy + sleeve + 28, 22, width, "bold");
    limited(item["artist"].toString(), x, sy + sleeve + 60, 14, width, "demibold");
    text("RHINE LAB · DISC", x, sy + sleeve + 96, 11);
}

/* ---------------- 封面：旋转 + 呼吸光晕 + 频谱环 ---------------- */
void NativeHud::aurumCover(double cx, double cy, double size, const QString &key, bool spinning,
                           double climax, bool oc) {
    const double half = size / 2;
    // 呼吸光晕（多层低透明圆近似径向渐变）
    const double haloR = half * 1.5;
    for (int i = 3; i >= 1; --i) {
        auto halo = dark ? QJsonArray{0.79, 0.80, 0.66, 0.05 * i} : QJsonArray{0.79, 0.80, 0.66, 0.10 * i};
        op({"ellipse", halo, cx - haloR * i / 3, cy - haloR * i / 3, haloR * 2 * i / 3, haloR * 2 * i / 3});
    }
    // 频谱环（封面之上、光晕之内）
    aurumSpectrumRing(cx, cy, size, climax, oc);
    // 圆形封面（唱片），旋转
    save();
    translate(cx, cy);
    rotate(spinning ? m_coverAngle : 0);
    translate(-cx, -cy);
    if (!key.isEmpty()) {
        op({"image-circle", key, cx - half, cy - half, size});
    } else {
        auto glass = ink();
        glass[3] = dark ? 0.10 : 0.62;
        op({"ellipse", glass, cx - half, cy - half, size, size});
    }
    restore();
}

void NativeHud::aurumSpectrumRing(double cx, double cy, double coverWidth, double climax, bool oc) {
    aurum::drawSpectrumRing([this](const QJsonArray &c) { op(c); }, cx, cy, coverWidth,
                            visual.spectrum(), climax, oc);
}

/* ---------------- 右：Aurum 竖屏播放器 ---------------- */
void NativeHud::aurumNowPlaying(double x, double y, double width, double height) {
    const auto &player = m_music->player;
    const auto item = m_music->current;
    const QJsonArray accent{119.0 / 255, 123.0 / 255, 96.0 / 255, 1};
    const double climax = visual.climax();
    const bool oc = true; // 超频（climax 辉光）常开

    // 顶栏：歌名 / 歌手（高潮发光 + 轻微放大由颜色提亮近似）
    auto title = item["title"].toString();
    if (title.isEmpty()) {
        title = "还没有放歌哦…";
    }
    const double titleSize = 24 + climax * 3;
    auto titleColor = QJsonArray{0.92, 0.92, 0.92, 1.0};
    if (dark) {
        titleColor[3] = 1.0;
    }
    titleColor[0] = std::min(1.0, titleColor[0].toDouble() + climax * 0.15);
    limited(title, x, y + 24, titleSize, width, "bold");
    auto artist = item["artist"].toString();
    if (artist.isEmpty()) {
        artist = "点一首嘛？人家等着呢";
    }
    auto dim = ink();
    dim[3] = dark ? 0.55 : 0.5;
    limited(artist, x, y + 58, 15, width, "demibold");

    // 封面区：居中，占满剩余高度
    const double coverSize = std::min(width * 0.82, (height - 160) * 0.92);
    const double cx = x + width / 2;
    const double cy = y + 110 + (height - 160) / 2;
    const bool playing = player.state["playing"].toBool();
    aurumCover(cx, cy, coverSize, player.coverImage, playing, climax, oc);
    m_aurumCoverRect = QRectF(cx - coverSize / 2, cy - coverSize / 2, coverSize, coverSize);

    // 进度：圆角细条 + 时间（封面下方）
    const double duration = player.state["duration"].toDouble();
    const double position = player.state["position"].toDouble();
    const double ratio = duration > 0 ? std::min(1.0, std::max(0.0, position / duration)) : 0;
    const double barX = x + width * 0.10;
    const double barW = width * 0.80;
    const double barY = y + height - 86;
    const double barH = 5;
    auto track = ink();
    track[3] = dark ? 0.22 : 0.14;
    op({"fill-path", aurumRounded(barX, barY, barW, barH, barH / 2), track});
    if (ratio > 0) {
        const double filled = std::max(barH, barW * ratio);
        op({"fill-path", aurumRounded(barX, barY, filled, barH, barH / 2), accent});
        op({"ellipse", accent, barX + filled - 5, barY - 3, 10, 10});
    }
    playerSeekRect = QRectF(barX, barY - 10, barW, 24);
    hit(barX, barY - 10, barW, 24, "player:seek-fraction", "播放进度");
    const auto dClk = [](double ms) {
        const int s = int(ms / 1000);
        return QString("%1:%2").arg(s / 60).arg(s % 60, 2, 10, QChar('0'));
    };
    text(dClk(position), barX, barY + 14, 12, "regular", 0, dim);
    text(dClk(duration), barX + barW, barY + 14, 12, "regular", 0, dim);

    // 控制簇：模式 · 上一首 · 播放/暂停 · 下一首 · 歌词
    const double ctrlY = y + height - 34;
    auto ctrl = ink();
    ctrl[3] = dark ? 0.85 : 0.7;
    static const QHash<QString, QString> modes{
        {"off", "顺序"}, {"all", "循环"}, {"one", "单曲"}, {"shuffle", "随机"}};
    centeredText(modes.value(player.mode), x + width * 0.12, ctrlY, 13, "regular", true);
    hit(x + width * 0.04, ctrlY - 20, width * 0.16, 40, "player:mode", "播放模式");

    const auto skip = [&](double cxx, bool forward) {
        op({"fill-path", aurumTriangle(cxx, ctrlY, 20, forward), ctrl});
        const double bar = forward ? cxx + 10 : cxx - 12;
        fill(bar, ctrlY - 10, 3, 20, ctrl);
    };
    skip(x + width * 0.34, false);
    hit(x + width * 0.30, ctrlY - 22, 44, 44, "player:prev", "上一首");
    // 播放/暂停实心圆
    op({"ellipse", accent, x + width / 2 - 26, ctrlY - 26, 52, 52});
    if (player.loading) {
        for (int i = -1; i <= 1; ++i) {
            op({"ellipse", QJsonArray{0.98, 0.98, 0.95, 1}, x + width / 2 + i * 9 - 2, ctrlY - 3, 5, 5});
        }
    } else if (playing) {
        fill(x + width / 2 - 8, ctrlY - 10, 6, 20, QJsonArray{0.98, 0.98, 0.95, 1});
        fill(x + width / 2 + 2, ctrlY - 10, 6, 20, QJsonArray{0.98, 0.98, 0.95, 1});
    } else {
        op({"fill-path", aurumTriangle(x + width / 2 + 2, ctrlY, 20, true), QJsonArray{0.98, 0.98, 0.95, 1}});
    }
    hit(x + width / 2 - 30, ctrlY - 30, 60, 60, "player:toggle", "播放 / 暂停");
    skip(x + width * 0.66, true);
    hit(x + width * 0.62, ctrlY - 22, 44, 44, "player:next", "下一首");
    centeredText("歌词", x + width * 0.88, ctrlY, 13, lyricsMode ? "demibold" : "regular", true);
    hit(x + width * 0.82, ctrlY - 20, width * 0.16, 40, "player:lyrics", "当前歌曲歌词");
}

/* ---------------- 整窗词云图层 ---------------- */
void NativeHud::aurumWordCloud(double width, double height, double climax) {
    auto &player = m_music->player;
    const auto doc = player.lyrics.document();
    const auto lines = doc["lines"].toArray();
    if (lines.isEmpty()) {
        return;
    }
    // 封面圆禁区：复用右竖屏播放器本帧算出的封面舞台坐标
    const QRectF coverRect = m_aurumCoverRect;

    const double position = player.state["position"].toDouble();
    aurumCloud.tick(position, lines, width, height, climax, true, &coverRect);
    if (!aurumCloud.advance()) {
        // 无活词，不绘制
    }
    aurumCloud.draw([this](const QJsonArray &c) { op(c); }, width, height, climax, true);
}
