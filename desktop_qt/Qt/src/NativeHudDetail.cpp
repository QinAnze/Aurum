#include "NativeHud.h"
#include "MusicData.h"
#include <algorithm>
#include <cmath>

QString NativeHud::body() const {
    const auto item = m_music->current;
    if (item.isEmpty()) {
        return {};
    }
    if (item["kind"] == "song") {
        if (tab == "overview") {
            const auto wiki = item["wiki"].toString();
            if (!wiki.isEmpty()) {
                return wiki;
            }
            return m_music->detailLoading ? "正在读取歌曲百科…" : "暂无歌曲百科";
        }
        auto date = item["date"].toString();
        auto description = item["description"].toString();
        if (date.isEmpty()) {
            date = "暂无";
        }
        if (description.isEmpty()) {
            description = "暂无专辑介绍";
        }
        return "专辑：" + item["album"].toString() + "\n歌手：" + item["artist"].toString() + "\n发行日期：" +
               date + "\n" + description;
    }
    if (tab == "overview") {
        const auto description = item["description"].toString();
        return description.isEmpty() ? "暂无简介" : description;
    }
    return "编号：" + item["id"].toString() + "\n名称：" + item["title"].toString() + "\n" +
           item["artist"].toString() + "\n已载入 " + QString::number(m_music->tracks.size()) + " 首";
}

void NativeHud::detail(double width, double opacity) {
    auto &music = *m_music;
    const auto item = music.current;
    if (item.isEmpty()) {
        archive(width);
        return;
    }
    if (item["kind"] != "song") {
        container(width, opacity);
        return;
    }
    const auto x = width * 0.56;
    if (lyricsMode && MusicPlayer::identity(item) != MusicPlayer::identity(music.player.current)) {
        lyricsMode = false;
    }
    const auto usable = width - x - 59;
    constexpr double gap = 12;
    const auto buttonWidth = (usable - gap * 2) / 3;
    save();
    alpha(opacity);
    if (!lyricsMode) {
        fill(x - 24, 260, usable + 48, 696,
             dark ? QJsonArray{0.08, 0.095, 0.09, 0.96} : QJsonArray{0.929, 0.922, 0.894, 0.96});
    }
    button("← 返回资料库   ESC", 59, 211, 360, 54, "back", 20, "demibold");
    limited(item["id"].toString(), 60, 845, 37, 330);
    text("MUSIC DATABASE", 60, 893, 10);
    text("DRAG TO INSPECT", 60, 917, 10);
    button("查看封面 ↗", 60, 944, 260, 35, "viewer", 14);
    if (lyricsMode) {
        lyricsPanel(x, usable);
        restore();
        return;
    }
    text("SONG ID / " + item["id"].toString(), x, 278, 12);
    const auto titleLines = m_glyphs->wrap(item["title"].toString(), usable, 32);
    for (int index = 0; index < std::min(2, int(titleLines.size())); ++index) {
        auto line = titleLines.at(index);
        if (index == 1 && titleLines.size() > 2) {
            line += "…";
        }
        limited(line, x, 305 + index * 40, 32, usable, "bold");
    }
    limited(item["artist"].toString(), x, 394, 19, usable, "demibold");
    if (music.editable()) {
        const bool liked = (music.likedIDs && MusicData::indexOf(*music.likedIDs, item["id"]) >= 0) ||
                           MusicData::indexOfId(music.lists[1], item["id"].toString()) >= 0;
        actionButton(liked ? "♥ 已喜欢" : "♡ 喜欢", x, 436, buttonWidth, "music:like");
        actionButton("加入歌单", x + buttonWidth + gap, 436, buttonWidth, "music:add-to-playlist");
    }
    if (!item["artists"].toArray().isEmpty()) {
        actionButton("歌手作品 ↗", x + (buttonWidth + gap) * 2, 436, buttonWidth, "music:artist:0");
    }
    actionButton("▶ 面板内播放", x, 498, buttonWidth, "music:play", true);
    actionButton("加入队列", x + buttonWidth + gap, 498, buttonWidth, "music:enqueue");
    actionButton("下一首播放", x + (buttonWidth + gap) * 2, 498, buttonWidth, "music:play-next");
    rule(x, 565, usable, 0.4);
    const auto column = (usable - gap) / 2;
    const QVector<QPair<QString, QString>> meta{{"ARTIST / 歌手", item["artist"].toString()},
                                                {"ALBUM / 专辑", item["album"].toString()},
                                                {"DURATION / 时长", MusicData::time(item)},
                                                {"PLAYBACK / 播放方式", "面板内播放 / 官方入口"}};
    for (int index = 0; index < meta.size(); ++index) {
        const auto xx = x + (index % 2) * (column + gap);
        const auto yy = 584 + (index / 2) * 64;
        text(meta.at(index).first, xx, yy, 11);
        const auto value = meta.at(index).second;
        limited(value.isEmpty() ? "暂无" : value, xx, yy + 23, 16, column - 12);
    }
    const QStringList keys{"overview", "notes", "history"};
    const QStringList labels{"歌曲百科", "专辑信息", "同专辑"};
    for (int index = 0; index < keys.size(); ++index) {
        const auto xx = x + index * usable / 3;
        button(labels.at(index), xx, 720, usable / 3 - 12, 38, "tab:" + keys.at(index), 15);
        if (tab == keys.at(index)) {
            rule(xx, 760, usable / 3 - 24, 1);
        }
    }
    rule(x, 762, usable, 0.2);
    if (tab == "history") {
        const auto songs = MusicData::slice(music.tracks, trackOffset, 2);
        for (int index = 0; index < songs.size(); ++index) {
            const auto song = songs.at(index).toObject();
            const auto yy = 790 + index * 48;
            text(MusicData::pad(trackOffset + index + 1), x, yy, 11);
            limited(song["title"].toString() + " / " + song["artist"].toString(), x + 35, yy, 16,
                    usable - 115);
            text(MusicData::time(song), x + usable - 65, yy, 12);
            rule(x, yy + 36, usable, 0.2);
            hit(x, yy - 4, usable, 42, "music:track:" + QString::number(trackOffset + index),
                song["title"].toString());
        }
        if (music.tracks.isEmpty()) {
            text(music.detailLoading ? "正在载入曲目…" : "暂无曲目信息", x, 790, 17);
        }
    } else {
        const auto lines = m_glyphs->wrap(body(), usable, 16);
        bodyOffset = std::min(bodyOffset, std::max(0, int(lines.size()) - 3));
        for (int index = 0; index < std::min(3, int(lines.size()) - bodyOffset); ++index) {
            text(lines.at(bodyOffset + index), x, 790 + index * 31, 16);
        }
    }
    actionButton(music.provider != "netease" ? music.providerName() + " ↗" : "官方客户端 ↗", x, 910,
                 buttonWidth, "music:official");
    if (music.editable() && music.directory && !music.uid.isEmpty() &&
        music.directory->item["creatorID"] == music.uid) {
        actionButton("从歌单移除", x + (buttonWidth + gap) * 2, 910, buttonWidth, "music:remove-track");
    }
    restore();
}

/** 歌词换文档或宽度时排版；进度更新只采样原生曲线并绘制可见行。 */
void NativeHud::lyricsPanel(double x, double width) {
    auto &player = m_music->player;
    auto &lyrics = player.lyrics;
    auto muted = ink();
    muted[3] = 0.45;
    limited(player.current["title"].toString(), x, 278, 20, width - 85, "demibold");
    limited(player.current["artist"].toString(), x, 310, 13, width - 85);
    button("关闭", x + width - 60, 278, 60, 40, "player:lyrics-close", 14);
    constexpr double top = 360;
    constexpr double bottom = 889;
    const auto document = lyrics.document();
    const auto lines = document["lines"].toArray();
    if (lines.isEmpty()) {
        save();
        clip(x, top, width, bottom - top);
        const auto plain = document["plainText"].toString();
        auto message = plain.isEmpty() ? lyrics.message : plain;
        if (message.isEmpty()) {
            message = "播放歌曲后显示歌词";
        }
        const auto size = plain.isEmpty() ? 24 : 27;
        const auto rows = m_glyphs->wrap(message, width - 24, size);
        m_lyricsPlainOffset = std::min(m_lyricsPlainOffset, std::max(0, int(rows.size()) - 9));
        for (int index = 0; index < std::min(9, int(rows.size()) - m_lyricsPlainOffset); ++index) {
            text(rows.at(m_lyricsPlainOffset + index), x, top + 55 + index * 48, size, "bold", 0, muted);
        }
        restore();
        if (lyrics.status == "error" || lyrics.status == "empty") {
            button("重新查找歌词 ↗", x, 909, 170, 36, "player:lyrics-retry", 14);
        }
        return;
    }
    constexpr double size = 34;
    if (m_lyricsDocument != document || m_lyricsWidth != width) {
        m_lyricsDocument = document;
        m_lyricsWidth = width;
        m_lyricsLayout.clear();
        double height = 0;
        for (const auto &value : lines) {
            const auto line = value.toObject();
            auto original = line["text"].toString();
            if (original.isEmpty()) {
                original = "•••";
            }
            const auto wrapped = m_glyphs->wrap(original, width - 24, size, "bold");
            const auto translation = line["translation"].toString();
            QStringList translated;
            if (!translation.isEmpty()) {
                translated = m_glyphs->wrap(translation, width - 24, 17);
            }
            m_lyricsLayout.append({height, wrapped, translated});
            height += std::max(1, int(wrapped.size())) * 47 + translated.size() * 26 + 32;
        }
        m_lyricsBrowse.reset();
        m_lyricsPlainOffset = 0;
        m_lyricsTarget.reset();
        m_lyricsCurve.reset();
        m_lyricsScroll = m_lyricsLayout.at(std::clamp(lyrics.index, 0, int(m_lyricsLayout.size()) - 1)).top;
    }
    const auto active = std::clamp(lyrics.index, 0, int(m_lyricsLayout.size()) - 1);
    const auto target = m_lyricsBrowse.value_or(m_lyricsLayout.at(active).top);
    const auto sample =
        m_lyricsCurve ? m_lyricsCurve->sample(lastTime) : std::array<double, 2>{m_lyricsScroll, 0};
    m_lyricsScroll = sample[0];
    if (!m_lyricsTarget || target != *m_lyricsTarget) {
        m_lyricsTarget = target;
        if (reduced) {
            m_lyricsScroll = target;
            m_lyricsCurve.reset();
        } else {
            m_lyricsCurve.emplace(sample[0], target, sample[1], lastTime, m_lyricsBrowse ? 0.18 : 0.42);
        }
    }
    constexpr double focusY = top + 155;
    const auto activeTime = lyrics.index >= 0 ? lines.at(active).toObject()["startMs"] : QJsonValue();
    save();
    clip(x - 4, top, width + 8, bottom - top);
    for (int index = 0; index < lines.size(); ++index) {
        const auto line = lines.at(index).toObject();
        const auto &row = m_lyricsLayout.at(index);
        const auto y = focusY + row.top - m_lyricsScroll;
        const double height = row.text.size() * 47 + row.translation.size() * 26;
        if (y + height < top || y > bottom) {
            continue;
        }
        auto color = ink();
        const bool isActive = lyrics.index >= 0 && line["startMs"] == activeTime;
        const auto edge = std::clamp(std::min((y + height - top) / 55, (bottom - y) / 55), 0.0, 1.0);
        color[3] = (isActive ? 1 : 0.28) * edge;
        for (int rowIndex = 0; rowIndex < row.text.size(); ++rowIndex) {
            text(row.text.at(rowIndex), x, y + rowIndex * 47, size, "bold", 0, color);
        }
        color[3] = color.at(3).toDouble() * 0.65;
        for (int rowIndex = 0; rowIndex < row.translation.size(); ++rowIndex) {
            text(row.translation.at(rowIndex), x, y + row.text.size() * 47 + rowIndex * 26, 17, "regular", 0,
                 color);
        }
        if (player.state["seekable"].toBool()) {
            const auto hitY = std::max(top, y);
            const auto label = line["text"].toString();
            hit(x, hitY, width, std::max(0.0, std::min(bottom, y + height + 20) - hitY),
                "player:lyric-line:" + QString::number(index), label.isEmpty() ? "间奏" : label);
        }
    }
    restore();
    button("歌词提前 0.2s", x, 914, 132, 32, "player:lyrics-earlier", 13);
    button("歌词延后 0.2s", x + 142, 914, 132, 32, "player:lyrics-later", 13);
    QString offsetLabel = "未校准";
    if (lyrics.offsetMs != 0) {
        const auto direction = lyrics.offsetMs > 0 ? "已提前 " : "已延后 ";
        offsetLabel = QString(direction) + QString::number(std::abs(lyrics.offsetMs) / 1000, 'f', 1) + "s";
    }
    text(offsetLabel, x + 284, 922, 12, "regular", 0, muted);
    button("回到当前句", x + width - 125, 914, 125, 32, "player:lyrics-follow", 13);
}

void NativeHud::container(double width, double opacity) {
    auto &music = *m_music;
    const auto item = music.current;
    const auto layout = containerLayout(width);
    const auto left = layout.left;
    const auto sidebar = layout.sidebar;
    const auto x = layout.x;
    const auto usable = layout.width;
    const auto rowsY = layout.rowsY;
    const auto rowHeight = layout.rowHeight;
    const auto rowCount = layout.rowCount;
    const bool albums = item["kind"] == "artist" && artistTab == "albums";
    QJsonArray songs = music.tracks;
    if (albums) {
        songs = music.directory ? music.directory->albums : QJsonArray();
    } else if (music.directory) {
        songs = music.directory->songs;
    }
    const auto sx = left + 19;
    const auto sideWidth = sidebar - 38;
    const auto coverSize = std::min(220.0, sideWidth);
    trackOffset = std::min(trackOffset, std::max(0, int(songs.size()) - rowCount));
    save();
    alpha(opacity);
    fill(left, layout.top, width - left * 2, layout.bottom - layout.top,
         dark ? QJsonArray{0.08, 0.095, 0.09, 1} : QJsonArray{0.929, 0.922, 0.894, 1});
    rule(x - 18, 278, 1, 0.12);
    button("← 返回曲目资料库   ESC", sx, 211, sideWidth, 54, "music:directory", 20, "demibold");
    QString collection = "PLAYLIST / 歌单";
    if (item["kind"] == "album") {
        collection = "ALBUM / 专辑";
    } else if (item["kind"] == "artist") {
        collection = "ARTIST / 歌手";
    }
    text(collection, sx, 325, 11);
    image(music.coverImage, sx, 355, coverSize, coverSize);
    limited(item["title"].toString(), sx, coverSize + 374, 20, sideWidth, "bold");
    limited(item["artist"].toString(), sx, coverSize + 410, 14, sideWidth);
    const QHash<QString, QString> prefixes{
        {"qq", "QQ MID / "}, {"kugou", "KUGOU ID / "}, {"netease", "NETEASE ID / "}};
    text(prefixes.value(music.provider) + item["id"].toString(), sx, coverSize + 449, 11);
    const auto ids = music.directory ? music.directory->ids.size() : 0;
    text(QString::number(std::max({item["trackCount"].toInt(), int(ids), int(songs.size())})) +
             " TRACKS / 曲目",
         sx, coverSize + 479, 12);
    const auto date = item["date"].toString();
    limited(date.isEmpty() ? "" : "发行日期：" + date, sx, coverSize + 510, 12, sideWidth);
    const auto description = item["description"].toString();
    const auto lines = m_glyphs->wrap(description.isEmpty() ? "暂无简介" : description, sideWidth, 12);
    for (int index = 0; index < std::min(3, int(lines.size())); ++index) {
        text(lines.at(index), sx, coverSize + 550 + index * 22, 12);
    }
    if (music.editable() && item["kind"] == "playlist" && item["creatorID"] == music.uid &&
        !music.uid.isEmpty()) {
        button("修改名称", sx, 866, sideWidth / 2, 30, "music:rename-playlist", 12);
        button("删除歌单", sx + sideWidth / 2, 866, sideWidth / 2, 30, "music:delete-playlist", 12);
    }
    if (music.editable()) {
        button("收藏 / 取消", sx, 913, sideWidth / 2, 32, "music:subscribe", 12);
    }
    button(music.providerName() + " ↗", sx + sideWidth / 2, 913, sideWidth / 2, 32, "music:source", 12);
    limited(item["title"].toString(), x, 279, 30, usable - 155, "bold");
    const auto total = music.directory ? music.directory->ids.size() : music.trackIDs.size();
    text(QString::number(songs.size()) + " / " +
             QString::number(std::max({item["trackCount"].toInt(), int(total), int(songs.size())})) + " 首",
         x + usable - 130, 289, 12);
    if (!albums) {
        fill(x, 339, 180, 44, {119.0 / 255, 123.0 / 255, 96.0 / 255, 1});
        hit(x, 339, 180, 44, "music:play-loaded", "播放全部");
        text("▶  播放全部", x + 22, 351, 16, "demibold", 0, {0.96, 0.95, 0.91, 1});
    }
    if (item["kind"] == "artist") {
        button("热门歌曲", x + 210, 345, 110, 32, "music:artist-tab:songs", 13);
        button("发行专辑", x + 335, 345, 110, 32, "music:artist-tab:albums", 13);
    }
    rule(x, 399, usable, 0.4);
    const auto titleX = x + 49;
    const auto artistX = x + usable * 0.52;
    const auto albumX = x + usable * 0.75;
    const auto timeX = x + usable - 65;
    const QVector<QPair<QString, double>> columns{{"#", x},
                                                  {"TITLE / 歌曲", titleX},
                                                  {"ARTIST / 歌手", artistX},
                                                  {"ALBUM / 专辑", albumX},
                                                  {"TIME", timeX}};
    for (const auto &[label, position] : columns) {
        text(label, position, 412, 11);
    }
    for (int row = 0; row < rowCount && trackOffset + row < songs.size(); ++row) {
        const auto index = trackOffset + row;
        const auto song = songs.at(index).toObject();
        const auto yy = rowsY + row * rowHeight;
        if (music.directory && music.directory->index == index) {
            auto color = ink();
            color[3] = 0.055;
            fill(x - 8, yy, usable + 16, rowHeight - 2, color);
        }
        text(MusicData::pad(index + 1), x, yy + 16, 12);
        limited(song["title"].toString(), titleX, yy + 12, 18, artistX - titleX - 22, "demibold");
        limited(song["artist"].toString(), artistX, yy + 16, 12, albumX - artistX - 20);
        limited(song["album"].toString(), albumX, yy + 16, 12, timeX - albumX - 18);
        auto stamp = MusicData::time(song);
        if (albums) {
            stamp = song["date"].toString();
            if (stamp.isEmpty()) {
                stamp = "专辑";
            }
        }
        limited(stamp, timeX, yy + 16, 12, 65);
        rule(x, yy + rowHeight - 1, usable, 0.15);
        hit(x - 8, yy, usable + 16, rowHeight - 2,
            (albums ? "music:artist-album:" : "music:track:") + QString::number(index),
            song["title"].toString());
    }
    if (songs.isEmpty()) {
        limited(music.directoryLoading || music.detailLoading ? "正在载入曲目…" : "暂无可读取曲目", titleX,
                490, 22, usable - 100);
    }
    text("滚轮浏览曲目 · 点击查看歌曲", x, 934, 11);
    if (albums && music.directory && music.directory->albumsMore) {
        button(music.directory->albumsLoading ? "载入中…" : "更多专辑 ↓", x + usable - 150, 922, 150, 32,
               "music:artist-more", 12);
    }
    if (!albums && songs.size() < total) {
        button(music.directoryLoading ? "载入中…" : "加载更多 ↓", x + usable - 150, 922, 150, 32,
               "music:directory-more", 12);
    }
    if (songs.size() > rowCount) {
        const auto height = rowCount * rowHeight - 2;
        auto color = ink();
        color[3] = 0.12;
        fill(x + usable + 14, rowsY, 2, height, color);
        const auto thumb = std::max(28.0, height * rowCount / songs.size());
        const auto fraction = double(trackOffset) / std::max(1, int(songs.size()) - rowCount);
        color[3] = 0.6;
        fill(x + usable + 14, rowsY + fraction * (height - thumb), 2, thumb, color);
    }
    restore();
}

void NativeHud::viewer(double width) {
    const auto item = m_music->current;
    if (item.isEmpty()) {
        return;
    }
    button("← 返回音乐   ESC", 59, 69, 300, 54, "viewer:close", 20, "demibold");
    text("RHINE LAB / MUSIC DATABASE / COVER", width / 2 - 145, 70, 11, "regular", 1.5);
    limited(item["title"].toString() + " / 封面", width / 2 - 145, 95, 28, width / 2 - 250, "demibold");
    text(item["id"].toString(), width / 2 - 145, 139, 12);
    text("360°", width - 185, 72, 55, "light");
    button("清晰", width - 247, 189, 84, 38, "viewer:clear", 14);
    button("磨砂", width - 147, 189, 84, 38, "viewer:frosted", 14);
    text("拖动旋转     ↑ ↓ ← → 平移     滚轮缩放", 59, 965, 13);
    button("原始视角", width / 2 - 165, 914, 154, 46, "viewer:reset", 15);
    button("封面正面", width / 2 + 18, 914, 154, 46, "music:cover-front", 15);
    button("复位视角 ↗", width - 194, 914, 135, 46, "viewer:reset", 14);
}
