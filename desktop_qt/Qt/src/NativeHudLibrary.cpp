#include "NativeHud.h"
#include "MusicData.h"
#include "MusicDiscover.h"
#include <QUrl>
#include <algorithm>

void NativeHud::libraryPanel(double x, double y, double width) {
    auto &music = *m_music;
    if (modal == "saved" && music.editable()) {
        button("＋ 创建歌单", x + width - 220, y + 147, 167, 33, "music:create-playlist", 12);
    }
    rule(x + 53, y + 248, width - 106);
    QStringList filters{"歌曲", "专辑", "歌单", "歌手"};
    if (modal == "saved") {
        filters = music.columns.mid(1, music.provider == "kugou" ? 3 : 4);
    } else if (music.provider == "qq") {
        filters = {"歌曲"};
    }
    const auto selected = modal == "saved"
                              ? musicCollection - 1
                              : QStringList{"song", "album", "playlist", "artist"}.indexOf(music.searchKind);
    for (int index = 0; index < filters.size(); ++index) {
        const auto spacing = std::min(145.0, (width - 106) / 8);
        const auto xx = x + 53 + index * spacing;
        const auto action = modal == "saved" ? "music:collection:" + QString::number(index + 1)
                                             : "music:kind:" + QString::number(index);
        button(filters.at(index), xx, y + 266, spacing - 5, 34, action, 12);
        if (index == selected) {
            rule(xx, y + 303, std::min(110.0, (width - 106) / 8 - 10), 1);
        }
    }
    const auto lane = modal == "saved" ? musicCollection : 0;
    const bool songs =
        std::any_of(music.lists[lane].begin(), music.lists[lane].end(),
                    [](const QJsonValue &value) { return value.toObject()["kind"] == "song"; });
    if (songs) {
        const QStringList labels{"原序", "歌手分组", "专辑分组"};
        const QStringList keys{"none", "artist", "album"};
        for (int index = 0; index < labels.size(); ++index) {
            const auto xx = x + width - 340 + index * 96;
            button(labels.at(index), xx, y + 266, 94, 34, "music:group:" + QString::number(index), 12);
            if (groupBy == keys.at(index)) {
                rule(xx, y + 303, 85, 1);
            }
        }
    }
    if (!activeGroup.isEmpty()) {
        button("← 全部分组", x + 53, y + 315, 230, 54, "music:group-back", 20, "demibold");
    } else {
        text("ID / 编号", x + 53, y + 329, 10);
        text("TITLE / 音乐", x + 160, y + 329, 10);
    }
    text("OPEN", x + width - 136, y + 329, 10);
    const auto values = rows(lane);
    listOffset = std::min(listOffset, std::max(0, int(values.size()) - 5));
    QStringList ids;
    for (const auto &entry : values) {
        ids.append(entry.value["key"].toString(entry.value["id"].toString()));
    }
    const auto signature =
        QStringList{modal,       QString::number(lane),       music.keyword, music.searchKind, query, groupBy,
                    activeGroup, QString::number(listOffset), ids.join('|')}
            .join('|');
    for (int index = 0; index < 5 && listOffset + index < values.size(); ++index) {
        const auto &entry = values.at(listOffset + index);
        const auto sample = rowMotion(signature, index);
        const auto yy = y + (activeGroup.isEmpty() ? 365 : 385) + index * 76 + sample[1];
        save();
        alpha(sample[0]);
        rule(x + 53, yy - 12, width - 106, 0.2);
        limited(entry.value["id"].toString(), x + 53, yy, 12, 100);
        limited(entry.value["title"].toString(), x + 160, yy, 20, width - 350, "demibold");
        const auto kind = entry.value["kind"].toString();
        auto artist = entry.value["artist"].toString();
        if (artist.isEmpty()) {
            artist = entry.value["album"].toString();
        }
        limited((kind == "group" ? "GROUP" : kind.toUpper()) + " / " + artist, x + 160, yy + 30, 11,
                width - 350);
        text("查看 ↗", x + width - 136, yy + 8, 12);
        if (sample[0] > 0.1) {
            const auto action =
                kind == "group"
                    ? "music:expand:" +
                          QString::fromUtf8(QUrl::toPercentEncoding(entry.value["key"].toString()))
                    : "music:result:" + QString::number(lane) + ":" + QString::number(entry.index);
            hit(x + 53, yy - 10, width - 106, 70, action, entry.value["title"].toString());
        }
        restore();
    }
    if (values.isEmpty()) {
        auto message = music.status;
        if (music.sourceLoading()) {
            message = "正在读取音乐…";
        } else if (lane > 0 && music.uid.isEmpty()) {
            message = "登录后查看个人音乐";
        }
        limited(message, x + 53, y + 501, 22, width - 106);
        if (lane > 0 && music.uid.isEmpty()) {
            button("登录" + music.providerName() + " →", x + 53, y + 561, 300, 40, "music:login", 16);
        }
    }
    limited(music.status, x + 53, y + 785, 11, std::max(100.0, width - 650));
    if (values.size() > 5) {
        button("上一页 ↑", x + width - 585, y + 775, 100, 35, "music:page-prev", 12);
        text(QString::number(listOffset + 1) + "–" +
                 QString::number(std::min(int(values.size()), listOffset + 5)) + " / " +
                 QString::number(values.size()),
             x + width - 475, y + 785, 11);
        if (listOffset + 5 < values.size() || music.hasMore[lane]) {
            button("下一页 ↓", x + width - 350, y + 775, 100, 35, "music:page-next", 12);
        }
    }
    if (!music.sourceLoading() && music.hasMore[lane]) {
        button("加载更多 ↓", x + width - 200, y + 775, 147, 35, "music:more:" + QString::number(lane), 12);
    }
}

void NativeHud::discoverPanel(double x, double y, double width) {
    const auto &music = *m_music;
    const auto &discover = *music.discover;
    const auto left = x + 53;
    const auto usable = width - 106;
    QVector<QPair<QString, QString>> tabs{{"playlists", music.provider == "qq" ? "榜单列表" : "推荐歌单"},
                                          {"daily", music.provider == "qq" ? "首页推荐" : "每日推荐"},
                                          {"charts", "排行榜"},
                                          {"albums", "新专辑"},
                                          {"categories", "分类歌单"}};
    if (music.provider == "netease") {
        tabs.append(QPair<QString, QString>{"artists", "收藏歌手"});
    }
    tabs.append(QPair<QString, QString>{"history", "历史"});
    for (int index = 0; index < tabs.size(); ++index) {
        const auto [key, label] = tabs.at(index);
        const auto xx = left + index * usable / tabs.size();
        button(label, xx, y + 195, usable / tabs.size() - 4, 33, "discover:tab:" + key, 12);
        if (discover.tab == key) {
            rule(xx, y + 231, usable / tabs.size() - 15, 1);
        }
    }
    if (discover.tab == "categories") {
        QJsonArray categories{QJsonObject{{"id", "全部"}, {"name", "全部"}}};
        for (const auto &category : discover.categories) {
            categories.append(category);
        }
        int selected = -1;
        for (int index = 0; index < categories.size(); ++index) {
            if (categories.at(index).toObject()["id"] == discover.category) {
                selected = index;
                break;
            }
        }
        const auto next = categories.at((selected + 1) % categories.size()).toObject();
        const auto current = selected < 0 ? QJsonObject() : categories.at(selected).toObject();
        button("分类：" + current["name"].toString("全部") + " →", left, y + 244, usable, 33,
               "discover:category:" + QString::fromUtf8(QUrl::toPercentEncoding(next["id"].toString())), 12);
    }
    rule(left, y + 286, usable, 0.5);
    listOffset = std::min(listOffset, std::max(0, int(discover.items.size()) - 6));
    for (int row = 0; row < 6 && listOffset + row < discover.items.size(); ++row) {
        const auto index = listOffset + row;
        const auto value = discover.items.at(index).toObject();
        const auto yy = y + 307 + row * 67;
        text(MusicData::pad(index + 1), left, yy + 8, 11);
        limited(value["title"].toString(), left + 54, yy + 4, 20, usable * 0.6 - 65, "demibold");
        limited(value["artist"].toString(), left + usable * 0.64, yy + 8, 13, usable * 0.3 - 25);
        button(value["kind"] == "song" ? "播放 ▶" : "打开 ↗", left + usable - 68, yy - 3, 68, 35,
               "discover:item:" + QString::number(index), 11);
        rule(left, yy + 53, usable, 0.15);
        hit(left, yy - 4, usable, 60, "discover:item:" + QString::number(index), value["title"].toString());
    }
    if (discover.items.isEmpty()) {
        limited(discover.loading ? "正在读取音乐…" : discover.status, left, y + 434, 22, usable);
    }
    limited(discover.status, left, y + 755, 12, usable - 350);
    button("↑ 上一页", x + width - 340, y + 748, 95, 32, "discover:prev", 12);
    button("下一页 ↓", x + width - 225, y + 748, 95, 32, "discover:next", 12);
    if (discover.more) {
        button(discover.loading ? "载入中…" : "加载更多", x + width - 130, y + 748, 80, 32, "discover:more",
               12);
    }
}

void NativeHud::loginPanel(double x, double y, double width) {
    const auto &music = *m_music;
    QStringList methods{"qr"};
    if (music.provider == "qq") {
        methods = {"qr", "wechat"};
    } else if (music.provider == "netease") {
        methods = {"qr", "phone", "email"};
    }
    if (music.provider == "kugou") {
        const QStringList editions{"standard", "lite"};
        for (int index = 0; index < editions.size(); ++index) {
            const auto edition = editions.at(index);
            const QString label = edition == "lite" ? "酷狗概念版" : "酷狗标准版";
            button((music.kugouEdition == edition ? "✓ " : "") + label, x + 53 + index * 190, y + 207, 180,
                   35, "music:kugou-edition:" + edition, 13);
        }
        methods.clear();
    }
    const QHash<QString, QString> labels{
        {"qr", music.provider == "qq" ? "手机 QQ 扫码" : music.providerName() + "扫码"},
        {"wechat", "微信扫码"},
        {"phone", "手机登录"},
        {"email", "邮箱登录"}};
    for (int index = 0; index < methods.size(); ++index) {
        const auto method = methods.at(index);
        button(labels.value(method), x + 53 + index * 145, y + 207, 140, 35, "music:login-method:" + method,
               13);
    }
    if (QStringList{"qr", "wechat"}.contains(music.loginMethod)) {
        image(music.qr, x + width / 2 - 120, y + 260, 240, 240);
        if (music.provider == "qq") {
            const auto lines = m_glyphs->wrap(
                "QQ 音乐账号只允许本人 7 天内在最多 5 台设备上登录，如登录失败，请在设备管理中删除无用设备。",
                width - 106, 13);
            for (int index = 0; index < lines.size(); ++index) {
                text(lines.at(index), x + 53, y + 520 + index * 18, 13);
            }
        }
        if (music.canRegenerateLogin()) {
            button("重新生成二维码", x + 53, y + 626, 260, 40, "music:qr", 15);
        } else {
            const auto seconds = music.loginRetrySeconds();
            const auto label =
                seconds > 0 ? "请等待 " + QString::number(seconds) + " 秒后重新生成" : "正在处理扫码登录…";
            text(label, x + 53, y + 636, 15);
        }
    } else {
        text(music.loginMethod == "phone" ? "手机号码（中国大陆）" : "邮箱地址", x + 53, y + 278, 14);
        text("密码", x + 53, y + 391, 14);
        text("按 ENTER 登录", x + 53, y + 532, 12);
    }
    limited(music.loginStatus, x + 53, y + 600, 15, width - 106);
    button("本轮跳过账号验证", x + 53, y + 709, 350, 45, "close-modal", 16);
    text("凭据仅保存至本机钥匙串，不读取官方 App 的登录信息。", x + 53, y + 785, 11);
}
