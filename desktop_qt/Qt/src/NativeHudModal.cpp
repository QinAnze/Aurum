#include "NativeHud.h"
#include "MusicData.h"
#include <algorithm>

namespace {
struct Provider {
    QString id;
    QString name;
    QString label;
    QString detail;
};
const QVector<Provider> providers{
    {"netease", "网易云音乐", "NETEASE", "搜索 · 个人音乐 · 推荐 · 播放 · 歌单编辑"},
    {"qq", "QQ 音乐", "QQ MUSIC", "歌曲搜索 · 个人音乐 · 首页推荐 · 播放"},
    {"kugou", "酷狗音乐", "KUGOU", "标准版 / 概念版 · 个人歌单 · 推荐与榜单 · 播放"}};

QString modalTitle(const QString &modal, const MusicLibrary &music) {
    static const QHash<QString, QString> titles{{"provider", "MUSIC PLATFORM"},
                                                {"settings", "SYSTEM SETTINGS"},
                                                {"saved", "MY MUSIC"},
                                                {"player", "NOW PLAYING"},
                                                {"discover", "DISCOVER MUSIC"},
                                                {"playlist-form", "PLAYLIST EDITOR"},
                                                {"playlist-picker", "PLAYLIST DIRECTORY"},
                                                {"confirm", "CONFIRM DELETE"}};
    if (modal == "login") {
        if (music.provider == "qq") {
            return "QQ MUSIC LOGIN";
        }
        if (music.provider == "kugou") {
            return music.kugouEdition == "lite" ? "KUGOU CONCEPT LOGIN" : "KUGOU LOGIN";
        }
        return "NETEASE LOGIN";
    }
    return titles.value(modal, "MUSIC INDEX");
}
QString modalSubtitle(const QString &modal, const MusicLibrary &music) {
    static const QHash<QString, QString> subtitles{{"provider", "直接选择音乐平台 / 各平台账号独立保存"},
                                                   {"settings", "终端偏好设置"},
                                                   {"player", "播放队列 / QUEUE"},
                                                   {"discover", "推荐 / 排行榜 / 新专辑"},
                                                   {"playlist-form", "编辑我的歌单"},
                                                   {"playlist-picker", "添加到我的歌单"},
                                                   {"confirm", "删除确认"}};
    if (modal == "saved") {
        return "我的音乐 / " + music.nickname;
    }
    if (modal == "login") {
        return music.provider == "kugou" ? "使用对应版本酷狗 App 扫码；搜索与个人音乐需要登录"
                                         : "可选登录，公开搜索不需要账号";
    }
    return subtitles.value(modal, "音乐检索");
}
}

/** 弹窗共用一次绘制栈与命中表，关闭曲线结束后才释放当前面板。 */
void NativeHud::modalDraw(double width) {
    auto &music = *m_music;
    save();
    alpha(motion.opacity);
    const bool search = modal == "search";
    fill(0, 0, width, 1080,
         dark ? QJsonArray{17.0 / 255, 24.0 / 255, 27.0 / 255, search ? 0.15 : 0.6}
              : QJsonArray{227.0 / 255, 224.0 / 255, 215.0 / 255, search ? 0.12 : 0.45});
    translate(0, motion.offset);
    const auto bounds = modalBounds(width);
    const auto x = bounds.x();
    const auto y = bounds.y();
    const auto usable = bounds.width();
    fill(x, y, usable, 836,
         dark ? QJsonArray{0.15, 0.15, 0.15, 1, "calibratedWhite"} : QJsonArray{0.929, 0.922, 0.894, 1});
    hits = {};
    m_modalControls = true;
    QString category = "MUSIC DIRECTORY";
    if (modal == "settings") {
        category = "SYSTEM PREFERENCES";
    } else if (modal == "player") {
        category = "AUDIO TERMINAL";
    }
    text("RHINE LAB / MUSIC DATABASE / " + category, x + 53, y + 37, 11);
    button("← 返回", x + usable - 220, y + 18, 167, 54, "close-modal", 20, "demibold");
    text(modalTitle(modal, music), x + 53, y + 91, 38, "demibold");
    text(modalSubtitle(modal, music), x + 53, y + 147, 15);
    if (modal == "provider") {
        platformPanel(x, y, usable);
    } else if (modal == "confirm") {
        limited(confirmTitle, x + 53, y + 260, 24, usable - 106, "demibold");
        text("此操作将同步至网易云。", x + 53, y + 330, 16);
        button("确认删除", x + 53, y + 450, 180, 45, "confirm:yes", 16);
        button("取消", x + 270, y + 450, 150, 45, "close-modal", 16);
    } else if (modal == "playlist-picker") {
        text("选择我的歌单", x + 53, y + 240, 18);
        for (int index = 0; index < 7 && listOffset + index < music.lists[2].size(); ++index) {
            const auto value = music.lists[2].at(listOffset + index).toObject();
            button(fit(value["title"].toString(), 18, usable - 106), x + 53, y + 290 + index * 60,
                   usable - 106, 52, "music:playlist-pick:" + value["id"].toString(), 18);
        }
        button("↑ 上一页", x + usable - 330, y + 758, 120, 32, "music:picker-prev", 12);
        button("下一页 ↓", x + usable - 190, y + 758, 120, 32, "music:picker-next", 12);
        limited(music.status, x + 53, y + 775, 12, usable - 420);
    } else if (modal == "playlist-form") {
        text(formKind == "create" ? "歌单名称" : "新歌单名称", x + 53, y + 240, 15);
        text("按 ENTER 提交", x + 53, y + 420, 12);
        limited(music.status, x + 53, y + 775, 12, usable - 106);
    } else if (modal == "discover") {
        discoverPanel(x, y, usable);
    } else if (modal == "player") {
        playerPanel(x, y, usable);
    } else if (modal == "settings") {
        settings(x, y, usable);
    } else if (modal == "login") {
        loginPanel(x, y, usable);
    } else {
        libraryPanel(x, y, usable);
    }
    m_modalControls = false;
    restore();
}

void NativeHud::platformChoices(double x, double y, double width, bool expanded) {
    constexpr double gap = 12;
    const auto cardWidth = (width - gap * 2) / 3;
    for (int index = 0; index < providers.size(); ++index) {
        const auto &provider = providers.at(index);
        const auto left = x + index * (cardWidth + gap);
        const bool selected = m_music->provider == provider.id;
        const auto height = expanded ? 190 : 66;
        const auto tint = dark ? QJsonArray{0.55, 0.59, 0.46, selected ? 0.3 : 0.12}
                               : QJsonArray{0.44, 0.49, 0.36, selected ? 0.23 : 0.09};
        fill(left, y, cardWidth, height, tint);
        hit(left, y, cardWidth, height, "provider:" + provider.id, provider.name);
        if (selected) {
            fill(left, y, 3, height, dark ? QJsonArray{0.7, 0.75, 0.53, 1} : QJsonArray{0.44, 0.49, 0.36, 1});
        }
        text(provider.label + (selected ? " / ACTIVE" : ""), left + 16, y + 10, 10);
        text(provider.name, left + 16, y + 29, expanded ? 22 : 17, "demibold");
        if (expanded) {
            const auto lines = m_glyphs->wrap(provider.detail, cardWidth - 32, 14);
            for (int row = 0; row < std::min(3, int(lines.size())); ++row) {
                text(lines.at(row), left + 16, y + 75 + row * 21, 14);
            }
            const bool authenticated = m_host->hasCredential(provider.id);
            text(authenticated ? "本机已保存登录" : "未登录 / 可选择后扫码", left + 16, y + 150, 12);
        }
    }
}
void NativeHud::platformPanel(double x, double y, double width) {
    text("PROVIDER ACCESS / 音乐平台", x + 53, y + 222, 13, "demibold");
    platformChoices(x + 53, y + 258, width - 106, true);
    rule(x + 53, y + 490, width - 106, 0.2);
    text("切换平台会停止当前播放，各平台账号与个人音乐独立保存。", x + 53, y + 520, 15);
    text("网易云保留歌单编辑；QQ 与酷狗先提供读取和播放。", x + 53, y + 558, 15);
    button("账号登录 / " + m_music->providerName(), x + 53, y + 660, 330, 48, "music:login", 16);
}
void NativeHud::settings(double x, double y, double width) {
    const auto &music = *m_music;
    const auto left = x + 53;
    const auto usable = width - 106;
    text("PROVIDER ACCESS / 音乐平台", left, y + 184, 12, "demibold");
    const auto tint = dark ? QJsonArray{1, 1, 1, 0.025} : QJsonArray{0, 0, 0, 0.025};
    fill(left, y + 210, usable, 66, tint);
    text("当前平台 / " + music.providerName(), left + 12, y + 233, 17, "demibold");
    button("切换平台 ▾", left + usable - 235, y + 225, 225, 36, "provider", 13);
    button(music.uid.isEmpty() ? "登录 / " + music.providerName() : "退出登录 / " + music.nickname, left,
           y + 290, 340, 38, music.uid.isEmpty() ? "music:login" : "music:logout", 13);
    limited("各平台账号独立保存", left + 365, y + 301, 12, usable - 365);
    text("TERMINAL PREFERENCES / 终端偏好", left, y + 348, 12, "demibold");
    static const QHash<QString, QString> qualities{{"standard", "标准"}, {"higher", "较高"},
                                                   {"exhigh", "极高"},   {"lossless", "无损"},
                                                   {"hires", "Hi-Res"},  {"jymaster", "母带"}};
    QString theme = dark ? "暗色" : "亮色";
    if (themeMode == "system") {
        theme = "跟随系统";
    }
    QVector<QStringList> rows{{"COLOR THEME / 界面配色", theme, "theme"},
                              {"REDUCED MOTION / 动态效果", reduced ? "减少动态效果" : "完整动效", "motion"},
                              {"AUDIO QUALITY / 音质", qualities.value(music.player.quality), "quality"}};
    if (music.provider == "netease") {
        rows.append({"ALTERNATE SOURCE / 替代音源",
                     music.player.alternative ? "开启（音质由来源决定）" : "关闭", "alternative"});
    }
    rows.append({"OFFICIAL PLAYER / 官方窗口", m_host->activates() ? "播放时显示" : "尽量保持后台",
                 "music:activate"});
    for (int index = 0; index < rows.size(); ++index) {
        const auto &row = rows.at(index);
        const auto yy = y + 377 + index * 50;
        fill(left, yy, usable, 44, tint);
        text(row.at(0), left + 12, yy + 12, 15, "demibold");
        button(row.at(1), left + usable - 235, yy + 4, 225, 36, row.at(2), 13);
    }
    text("↑ ↓ 选曲 / ENTER 查看 / " + m_host->modifierKey() + " ENTER 播放 / ESC 返回", left, y + 654, 12);
    rule(left, y + 687, usable, 0.2);
    text("PROJECT / 项目与开源参考", left, y + 702, 10, "demibold");
    const QVector<QPair<QString, QString>> links{{"本项目 / Rhine Music Database ↗", "project-home"},
                                                 {"网易云音乐 API / api-enhanced ↗", "project-author"},
                                                 {"QQ 音乐 API / qq-music-api ↗", "project-player"},
                                                 {"酷狗音乐 API / KuGouMusicApi ↗", "project-kugou"},
                                                 {"界面原项目 / RhineLabUI ↗", "project-rhine"},
                                                 {"歌词参考 / LyricsX ↗", "project-lyricsx"},
                                                 {"格式移植 / LyricsKit ↗", "project-lyricskit"},
                                                 {"同步与匹配参考 / Lyrimuse ↗", "project-lyrimuse"}};
    const auto linkWidth = (usable - 280 - 12) / 2;
    for (int index = 0; index < links.size(); ++index) {
        button(links.at(index).first, left + (index % 2) * (linkWidth + 8), y + 725 + (index / 2) * 28,
               linkWidth, 25, "music:" + links.at(index).second, 11);
    }
    button("切换全屏 / F11", left + usable - 260, y + 725, 260, 36, "window:fullscreen", 13);
    button("REINITIALIZE SYSTEM ↻", left + usable - 260, y + 769, 260, 36, "replay", 13);
}
