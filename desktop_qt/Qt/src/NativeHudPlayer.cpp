#include "NativeHud.h"
#include "MusicData.h"
#include <algorithm>

namespace {
/// 圆角矩形路径。HUD 的绘制指令只认路径字符串，这里统一生成一次。
QString roundedRect(double x, double y, double w, double h, double r) {
    r = std::max(0.0, std::min(r, std::min(w, h) / 2));
    const auto n = [](double v) { return QString::number(v, 'f', 2); };
    const double x2 = x + w;
    const double y2 = y + h;
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

/// 三角形图标（播放 / 上下一首）
QString triangle(double cx, double cy, double size, bool forward) {
    const auto n = [](double v) { return QString::number(v, 'f', 2); };
    const double half = size / 2;
    if (forward) {
        return "M " + n(cx - half * 0.7) + " " + n(cy - half) + " L " + n(cx + half * 0.8) + " " + n(cy) +
               " L " + n(cx - half * 0.7) + " " + n(cy + half) + " Z";
    }
    return "M " + n(cx + half * 0.7) + " " + n(cy - half) + " L " + n(cx - half * 0.8) + " " + n(cy) +
           " L " + n(cx + half * 0.7) + " " + n(cy + half) + " Z";
}
}

/* ================================================================
   底部播放条 —— Aurum 视觉：玻璃面板 + 唱片封面 + 圆角进度 + 旋钮
   ================================================================ */
void NativeHud::playerBar(double, double y, double width) {
    const auto &player = m_music->player;
    const auto first = hits.size();

    // ---- 配色：玻璃面板始终是「比背景更亮的一层」，不跟随 ink 反色 ----
    const QJsonArray accent{119.0 / 255, 123.0 / 255, 96.0 / 255, 1};
    const QJsonArray glass = dark ? QJsonArray{1.0, 1.0, 1.0, 0.07} : QJsonArray{1.0, 1.0, 1.0, 0.72};
    const QJsonArray line = dark ? QJsonArray{1.0, 1.0, 1.0, 0.14}
                                 : QJsonArray{0.09, 0.09, 0.075, 0.10};
    auto dim = ink();
    dim[3] = dark ? 0.55 : 0.48; // 次要文字
    auto track = ink();
    track[3] = dark ? 0.20 : 0.14; // 进度条底
    const QJsonArray onAccent{0.98, 0.98, 0.95, 1};

    // ---- 玻璃面板 ----
    const double panelX = 20;
    const double panelY = y + 8;
    const double panelW = width - 40;
    const double panelH = 80;
    const double radius = 24;
    op({"fill-path", roundedRect(panelX, panelY, panelW, panelH, radius), glass});
    op({"path", roundedRect(panelX + 0.5, panelY + 0.5, panelW - 1, panelH - 1, radius - 0.5), 1, line,
        QJsonArray{}, 0});

    // ---- 封面（圆形，唱片感）----
    const double coverX = panelX + 22;
    const double coverY = panelY + 10;
    const double coverSize = 60;
    if (!player.coverImage.isEmpty()) {
        op({"image-circle", player.coverImage, coverX, coverY, coverSize});
        // 唱片中心孔
        auto hole = ink();
        hole[3] = dark ? 0.35 : 0.22;
        op({"ellipse", hole, coverX + coverSize / 2 - 5, coverY + coverSize / 2 - 5, 10, 10});
    } else {
        op({"ellipse", glass, coverX, coverY, coverSize, coverSize});
        op({"arc", coverX + coverSize / 2, coverY + coverSize / 2, coverSize / 2 - 0.5, 0, 6.2832, 1, line});
        op({"ellipse", line, coverX + coverSize / 2 - 7, coverY + coverSize / 2 - 7, 14, 14});
    }

    // ---- 歌名 / 歌手 ----
    const double textX = coverX + coverSize + 18;
    const double textW = width * 0.30;
    auto title = player.failed ? player.status : player.current["title"].toString();
    if (title.isEmpty() && !player.failed) {
        title = "尚未播放";
    }
    text(fit(title, 19, textW, "demibold"), textX, panelY + 34, 19, "demibold");
    auto artist = player.current["artist"].toString();
    if (artist.isEmpty()) {
        artist = "RHINE LAB / MUSIC DATABASE";
    }
    text(fit(artist, 12, textW), textX, panelY + 54, 12, "regular", 0, dim);

    // ---- 进度：圆角细条 + 圆头 ----
    const double duration = player.state["duration"].toDouble();
    const double position = player.state["position"].toDouble();
    const double ratio = duration > 0 ? std::min(1.0, std::max(0.0, position / duration)) : 0;
    const double barX = textX;
    const double barY = panelY + 64;
    const double barW = textW;
    const double barH = 4;
    op({"fill-path", roundedRect(barX, barY, barW, barH, barH / 2), track});
    if (ratio > 0) {
        const double filled = std::max(barH, barW * ratio);
        op({"fill-path", roundedRect(barX, barY, filled, barH, barH / 2), accent});
        op({"ellipse", accent, barX + filled - 4, barY - 2.5, 8, 8});
    }
    playerSeekRect = QRectF(barX, barY - 8, barW, 20);
    hit(barX, barY - 8, barW, 20, "player:open", "播放进度");
    text(clock(position) + " / " + clock(duration), barX + barW + 10, barY + 5, 11, "regular", 0, dim);

    // ---- 控制簇 ----
    const double ctrlX = width * 0.615;
    const double ctrlY = panelY + panelH / 2;

    static const QHash<QString, QString> modes{
        {"off", "顺序"}, {"all", "循环"}, {"one", "单曲"}, {"shuffle", "随机"}};
    centeredText(modes.value(player.mode), ctrlX - 128, ctrlY, 13, "regular", true);
    hit(ctrlX - 158, ctrlY - 22, 60, 44, "player:mode", "播放模式");

    // 上一首：两条竖线 + 左侧三角
    const auto skipIcon = [&](double cx, bool forward) {
        op({"fill-path", triangle(cx, ctrlY, 18, forward), ink()});
        const double bar = forward ? cx + 9 : cx - 11;
        fill(bar, ctrlY - 9, 2.5, 18, ink());
    };
    skipIcon(ctrlX - 66, false);
    hit(ctrlX - 88, ctrlY - 24, 44, 48, "player:prev", "上一首");

    // 播放 / 暂停：实心圆 + 图标
    op({"ellipse", accent, ctrlX - 24, ctrlY - 24, 48, 48});
    if (player.loading) {
        for (int index = -1; index <= 1; ++index) {
            op({"ellipse", onAccent, ctrlX + index * 8 - 2, ctrlY - 2, 4, 4});
        }
    } else if (player.state["playing"].toBool()) {
        fill(ctrlX - 7, ctrlY - 9, 5, 18, onAccent);
        fill(ctrlX + 2, ctrlY - 9, 5, 18, onAccent);
    } else {
        op({"fill-path", triangle(ctrlX + 2, ctrlY, 18, true), onAccent});
    }
    hit(ctrlX - 28, ctrlY - 28, 56, 56, "player:toggle", "播放 / 暂停");

    skipIcon(ctrlX + 66, true);
    hit(ctrlX + 44, ctrlY - 24, 44, 48, "player:next", "下一首");

    centeredText("歌词", ctrlX + 132, ctrlY, 13, lyricsMode ? "demibold" : "regular", true);
    hit(ctrlX + 106, ctrlY - 22, 52, 44, "player:lyrics", "当前歌曲歌词");

    // ---- 音量旋钮：270° 弧（底部留缺口）----
    const double volX = width - 138;
    const double volY = ctrlY;
    const double volR = 15;
    const double start = 2.356;   // 135°
    const double sweep = 4.712;   // 270°
    op({"arc", volX, volY, volR, start, sweep, 3, track});
    const double volume = std::max(0.0, std::min(1.0, player.state["volume"].toDouble()));
    if (volume > 0.001) {
        op({"arc", volX, volY, volR, start, sweep * volume, 3, accent});
    }
    op({"ellipse", ink(), volX - 2.5, volY - 2.5, 5, 5});
    playerVolumeRect = QRectF(volX - 34, volY - 30, 68, 60);
    hit(volX - 34, volY - 30, 68, 60, "player:open", "音量");

    centeredText("队列", width - 72, ctrlY, 12, "regular", true);
    hit(width - 108, ctrlY - 22, 76, 44, "player:open", "播放队列");

    // 底栏所有命中区固定，不随列表滚动
    for (auto index = first; index < hits.size(); ++index) {
        auto value = hits.at(index).toObject();
        value["fixed"] = true;
        hits[index] = value;
    }
}

void NativeHud::playerPanel(double x, double y, double width) {
    const auto &player = m_music->player;
    const auto left = x + 53;
    const auto usable = width - 106;
    rule(left, y + 216, usable);
    auto title = player.current["title"].toString();
    if (title.isEmpty()) {
        title = "选择歌曲开始播放";
    }
    limited(title, left, y + 240, 25, usable, "bold");
    limited(player.current["artist"].toString(), left, y + 278, 15, usable);
    text("QUEUE / " + QString::number(player.queue.size()) + " 首", left, y + 326, 15);
    button("清空待播", left + usable - 140, y + 311, 140, 44, "player:clear", 16);
    queueOffset = std::min(queueOffset, std::max(0, int(player.queue.size()) - 7));
    for (int row = 0; row < 7 && queueOffset + row < player.queue.size(); ++row) {
        const auto index = queueOffset + row;
        const auto song = player.queue.at(index).toObject();
        const auto yy = y + 371 + row * 48;
        text(index == player.index ? "▶" : MusicData::pad(index + 1), left, yy, 15);
        button(fit(song["title"].toString(), 18, usable - 110), left + 44, yy - 7, usable - 110, 40,
               "player:queue:" + QString::number(index), 18);
        if (index != player.index) {
            button("×", left + usable - 40, yy - 7, 40, 40, "player:remove:" + QString::number(index), 20);
        }
        rule(left, yy + 34, usable, 0.15);
    }
    limited(player.status, left, y + 730, 14, usable);
    static const QHash<QString, QString> modes{
        {"off", "顺序播放"}, {"all", "列表循环"}, {"one", "单曲循环"}, {"shuffle", "随机播放"}};
    button(modes.value(player.mode), left, y + 761, 140, 44, "player:mode", 16);
    button(m_music->provider != "netease" ? m_music->providerName() + " ↗" : "官方客户端 ↗", left + 165,
           y + 761, 175, 44, "player:official", 16);
    if (m_music->editable()) {
        button("♡ 喜欢此曲", left + 365, y + 761, 140, 44, "music:like-current", 16);
    }
}