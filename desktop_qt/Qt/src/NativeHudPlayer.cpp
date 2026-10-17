#include "NativeHud.h"
#include "MusicData.h"
#include <algorithm>

void NativeHud::playerBar(double, double y, double width) {
    const auto &player = m_music->player;
    const auto first = hits.size();
    const auto center = width / 2;
    auto shade = ink();
    shade[3] = 0.12;
    fill(0, y, width, 1080 - y,
         dark ? QJsonArray{0.075, 0.085, 0.075, 1} : QJsonArray{0.929, 0.922, 0.894, 1});
    const auto duration = player.state["duration"].toDouble();
    const auto position = duration != 0 ? std::min(1.0, player.state["position"].toDouble() / duration) : 0;
    fill(0, y, width, 3, shade);
    fill(0, y, width * position, 3, {119.0 / 255, 123.0 / 255, 96.0 / 255, 1});
    playerSeekRect = QRectF(0, y, width, 12);
    hit(0, y, width, 12, "player:open", "播放进度");
    constexpr double coverX = 28;
    const auto coverY = y + 17;
    if (!player.coverImage.isEmpty()) {
        image(player.coverImage, coverX, coverY, 64, 64);
    } else {
        op({"ellipse", shade, coverX, coverY, 64, 64});
        op({"ellipse", ink(), coverX + 28, coverY + 28, 8, 8});
    }
    const auto infoWidth = std::max(120.0, center - 280 - 116);
    auto title = player.failed ? player.status : player.current["title"].toString();
    if (title.isEmpty() && !player.failed) {
        title = "尚未播放";
    }
    centeredText(fit(title, 20, infoWidth, "demibold"), 116, y + 34, 20, "demibold");
    auto artist = player.current["artist"].toString();
    if (artist.isEmpty()) {
        artist = "RHINE LAB / MUSIC DATABASE";
    }
    centeredText(fit(artist, 15, infoWidth), 116, y + 64, 15);
    hit(28, y + 17, std::max(200.0, center - 280 - 28), 64, "player:open", "当前歌曲 / 播放队列");
    hit(center - 187, y + 20, 70, 44, "player:mode", "播放模式");
    static const QHash<QString, QString> modes{
        {"off", "顺序"}, {"all", "循环"}, {"one", "单曲"}, {"shuffle", "随机"}};
    centeredText(modes.value(player.mode), center - 152, y + 42, 16, "regular", true);
    hit(center - 99, y + 14, 44, 56, "player:prev", "上一首");
    const auto cy = y + 42;
    const QJsonArray icon{0.96, 0.95, 0.91, 1};
    const auto path = [](std::initializer_list<QPointF> points, bool closed = false) {
        QString value;
        for (const auto &point : points) {
            value += value.isEmpty() ? "M " : " L ";
            value += QString::number(point.x(), 'g', 16) + " " + QString::number(point.y(), 'g', 16);
        }
        if (closed) {
            value += " Z";
        }
        return value;
    };
    op({"path", path({{center - 72, cy - 10}, {center - 82, cy}, {center - 72, cy + 10}}), 3, ink(),
        QJsonArray{}, 0});
    op({"path", path({{center + 72, cy - 10}, {center + 82, cy}, {center + 72, cy + 10}}), 3, ink(),
        QJsonArray{}, 0});
    op({"ellipse", QJsonArray{119.0 / 255, 123.0 / 255, 96.0 / 255, 1}, center - 29, cy - 29, 58, 58});
    hit(center - 29, cy - 29, 58, 58, "player:toggle", "播放 / 暂停");
    if (player.loading) {
        for (int index = -1; index <= 1; ++index) {
            op({"ellipse", icon, center + index * 9 - 2, cy - 2, 4, 4});
        }
    } else if (player.state["playing"].toBool()) {
        fill(center - 9, cy - 11, 6, 22, icon);
        fill(center + 3, cy - 11, 6, 22, icon);
    } else {
        op({"fill-path", path({{center - 10, cy - 12}, {center + 10, cy}, {center - 10, cy + 12}}, true),
            icon});
    }
    hit(center + 55, y + 14, 44, 56, "player:next", "下一首");
    const auto lyricsX = width * 0.591;
    centeredText("歌词", lyricsX, cy, 15, lyricsMode ? "demibold" : "regular", true);
    hit(lyricsX - 27, cy - 23, 54, 46, "player:lyrics", "当前歌曲歌词");
    centeredText(clock(player.state["position"].toDouble()) + " / " + clock(duration), center, y + 84, 13,
                 "regular", true);
    const auto vx = width - 239;
    playerVolumeRect = QRectF(vx, cy - 24, 86, 48);
    centeredText("音量", vx - 54, cy, 15);
    for (int index = 0; index < 10; ++index) {
        const double height = 6 + index;
        fill(vx + index * 9, cy - height / 2, 4, height,
             index / 10.0 < player.state["volume"].toDouble() ? ink() : shade);
    }
    hit(width - 103, cy - 24, 70, 48, "player:open", "播放队列");
    centeredText("队列", width - 68, cy, 18, "regular", true);
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
