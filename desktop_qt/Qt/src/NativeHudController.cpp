#include "NativeHud.h"
#include "MusicData.h"
#include "MusicDiscover.h"
#include <QJsonDocument>
#include <QPointer>
#include <QUrl>
#include <algorithm>
#include <cmath>

namespace {
int wrap(int value, int count) {
    return count > 0 ? (value % count + count) % count : 0;
}

QString cycle(const QStringList &values, const QString &value) {
    return values.at(wrap(values.indexOf(value) + 1, values.size()));
}

QString decode(const QString &value) {
    return QUrl::fromPercentEncoding(value.toUtf8());
}
}

/** 建立原生界面状态与音乐通知；所有延迟动作都绑定控制器生命周期和查询代数。 */
NativeHud::NativeHud(Host *host, Glyphs *glyphs, MusicLibrary *music, HudSceneActions scene, QObject *parent)
    : QObject(parent), m_host(host), m_glyphs(glyphs), m_music(music), m_scene(std::move(scene)) {
    themeMode = host->preference("theme");
    if (themeMode.isEmpty()) {
        themeMode = "light";
    }
    dark = themeMode == "system" ? host->systemDark() : themeMode == "dark";
    reduced = host->preference("motion") == "reduced";
    connect(music, &MusicLibrary::invalidated, this, &NativeHud::finishPage);
}

void NativeHud::openModal(QString kind) {
    ++m_searchGeneration;
    if (m_scene.pointer) {
        m_scene.pointer("pointercancel", 0, 0, 0);
        m_scene.pointer("pointerleave", 0, 0, 0);
    }
    modal = kind;
    closing = false;
    motion.set(true, lastTime, reduced);
    query.clear();
    listOffset = 0;
    activeGroup.clear();
    artistTab = "songs";
    if (kind == "saved") {
        musicCollection = std::max(1, m_music->selectedLane);
        if (m_music->provider == "kugou" && musicCollection == 4) {
            musicCollection = 2;
        }
        if (m_music->lists[musicCollection].isEmpty()) {
            m_music->loadMoreSource(musicCollection);
        }
    }
    if (kind == "search") {
        query = m_music->keyword;
    }
}

void NativeHud::closeModal() {
    ++m_searchGeneration;
    if (modal == "login") {
        m_music->cancelLogin();
    }
    closing = true;
    motion.set(false, lastTime, reduced);
}

void NativeHud::setQuery(QString value) {
    query = value;
    listOffset = 0;
    activeGroup.clear();
    const auto token = ++m_searchGeneration;
    if (modal == "search") {
        const QPointer<NativeHud> owner(this);
        m_host->schedule(700, [owner, token, value]() {
            if (!owner || token != owner->m_searchGeneration) {
                return;
            }
            owner->m_music->search(value);
            if (owner->m_music->provider == "netease" && !owner->m_host->fromLink(value).isEmpty()) {
                owner->closeModal();
            }
        });
    }
}

void NativeHud::form(QJsonObject fields) {
    if (modal == "login" && QStringList{"phone", "email"}.contains(m_music->loginMethod) &&
        fields["account"].isString() && fields["password"].isString() &&
        fields["account"].toString().size() <= 100 && fields["password"].toString().size() <= 256) {
        m_music->passwordLogin(m_music->loginMethod, fields["account"].toString(),
                               fields["password"].toString());
    }
    if (modal == "playlist-form" && fields["name"].isString()) {
        const QPointer<NativeHud> owner(this);
        const auto token = m_searchGeneration;
        m_music->playlistForm(formKind, fields["name"].toString(), formPID, [owner, token](bool ok) {
            if (ok && owner && owner->m_searchGeneration == token && owner->modal == "playlist-form") {
                owner->closeModal();
            }
        });
    }
}

/** 查询分组只缓存当前修订；原始索引保留给资料库选择，合唱曲目可进入多个组。 */
QVector<NativeHud::Row> NativeHud::rows(int lane) {
    if (lane < 0 || lane >= 5) {
        return {};
    }
    const auto filter = modal == "saved" ? query.toLower() : QString();
    const auto key =
        QString::fromUtf8(QJsonDocument(QJsonArray{lane, double(m_music->revision),
                                                   m_music->lists[lane].size(), filter, groupBy, activeGroup})
                              .toJson(QJsonDocument::Compact));
    if (key == m_rowsKey) {
        return m_rows;
    }
    QVector<Row> values;
    for (int index = 0; index < m_music->lists[lane].size(); ++index) {
        const auto value = m_music->lists[lane].at(index).toObject();
        const auto title = value["title"].toString() + value["artist"].toString() + value["id"].toString();
        if (filter.isEmpty() || title.toLower().contains(filter)) {
            values.append({index, value, {}});
        }
    }
    const bool songs = std::any_of(values.cbegin(), values.cend(),
                                   [](const Row &row) { return row.value["kind"] == "song"; });
    if (groupBy != "none" && songs) {
        QVector<Row> groups;
        QVector<QVector<Row>> entries;
        QHash<QString, int> indices;
        for (const auto &row : values) {
            const auto value = row.value;
            if (value["kind"] != "song") {
                continue;
            }
            QVector<QPair<QString, QString>> labels;
            if (groupBy == "artist") {
                for (const auto &entry : value["artists"].toArray()) {
                    const auto artist = entry.toObject();
                    const auto id = artist["id"].toString();
                    const auto name = artist["name"].toString();
                    labels.append({id.isEmpty() ? "name:" + name : "artist:" + id, name});
                }
                if (labels.isEmpty()) {
                    auto name = value["artist"].toString();
                    labels.append({"name:" + name, name.isEmpty() ? "未知歌手" : name});
                }
            } else {
                const auto id = value["albumID"].toString();
                const auto album = value["album"].toString();
                labels.append({id.isEmpty() ? "album-name:" + album : "album:" + id,
                               album.isEmpty() ? "未知专辑" : album});
            }
            QSet<QString> seen;
            for (const auto &[label, title] : labels) {
                if (seen.contains(label)) {
                    continue;
                }
                seen.insert(label);
                if (!indices.contains(label)) {
                    indices.insert(label, groups.size());
                    groups.append(
                        {-1,
                         {{"kind", "group"}, {"key", label}, {"title", title}, {"album", "点击展开分组"}},
                         {}});
                    entries.append(QVector<Row>{});
                }
                const auto index = indices[label];
                entries[index].append(row);
                groups[index].indices.append(row.index);
            }
        }
        for (auto &group : groups) {
            group.value["id"] = QString::number(group.indices.size());
            group.value["artist"] = QString::number(group.indices.size()) + " 首已载入";
        }
        if (activeGroup.isEmpty()) {
            values = groups;
        } else {
            values = entries.value(indices.value(activeGroup, -1));
            if (m_music->groupLane == lane) {
                m_music->groupIndices.clear();
                for (const auto &row : values) {
                    m_music->groupIndices.append(row.index);
                }
            }
        }
    }
    m_rowsKey = key;
    m_rows = values;
    return values;
}

/** 分页等待音乐状态通知；弹窗、来源或查询变化后丢弃原来的翻页目标。 */
void NativeHud::pageResults(int direction) {
    if (closing || !QStringList{"search", "saved"}.contains(modal)) {
        return;
    }
    const auto lane = modal == "saved" ? musicCollection : 0;
    const auto desired = std::max(0, listOffset + direction * 5);
    m_page = Page{modal, lane, m_searchGeneration, desired};
    if (direction > 0 && desired > std::max(0, int(rows(lane).size()) - 5) && m_music->hasMore[lane] &&
        !m_music->sourceLoading()) {
        m_music->loadMoreSource(lane);
    }
    finishPage();
}

void NativeHud::finishPage() {
    if (!m_page) {
        return;
    }
    const auto page = *m_page;
    if (modal != page.modal || closing || m_searchGeneration != page.generation ||
        (modal == "saved" && page.lane != musicCollection)) {
        m_page.reset();
        return;
    }
    if (m_music->sourceLoading()) {
        return;
    }
    m_page.reset();
    listOffset = std::min(page.desired, std::max(0, int(rows(page.lane).size()) - 5));
}

void NativeHud::playerAction(const QStringList &parts) {
    auto &music = *m_music;
    auto &player = music.player;
    const auto name = parts.value(1);
    const auto value = parts.value(2).toDouble();
    const auto index = int(value);
    if (name == "lyrics") {
        if (!player.current.isEmpty()) {
            modal.clear();
            closing = false;
            lyricsMode = true;
            m_lyricsBrowse.reset();
            music.followPlayback(player.current);
            m_scene.mode("detail");
            frame["mode"] = "detail";
        }
    } else if (name == "lyrics-close") {
        lyricsMode = false;
    } else if (name == "lyrics-follow") {
        m_lyricsBrowse.reset();
    } else if (name == "lyrics-earlier" || name == "lyrics-later") {
        player.lyrics.adjustOffset(name == "lyrics-earlier" ? 200 : -200);
    } else if (name == "lyrics-retry") {
        if (!player.current.isEmpty()) {
            player.lyrics.load(player.current, true);
        }
    } else if (name == "lyric-line") {
        const auto document = player.lyrics.document();
        const auto lines = document["lines"].toArray();
        if (index >= 0 && index < lines.size() && player.state["seekable"].toBool()) {
            const auto position = lines.at(index).toObject()["startMs"].toDouble() -
                                  document["offsetMs"].toDouble() - player.lyrics.offsetMs;
            m_host->mediaControl("seek", std::clamp(position, 0.0, player.state["duration"].toDouble()));
            m_lyricsBrowse.reset();
        }
    } else if (name == "open") {
        openModal("player");
    } else if (name == "toggle") {
        player.toggle();
    } else if (name == "prev" || name == "next") {
        player.next(name == "prev" ? -1 : 1);
    } else if (name == "seek" || name == "seek-fraction") {
        player.seek(name == "seek" ? value / 20 : value);
    } else if (name == "volume" || name == "volume-fraction") {
        player.volume(name == "volume" ? value / 10 : value);
    } else if (name == "mode") {
        player.mode = cycle({"off", "all", "one", "shuffle"}, player.mode);
    } else if (name == "queue") {
        if (index >= 0 && index < player.queue.size()) {
            player.play(player.queue.at(index).toObject(), std::nullopt, index);
        }
    } else if (name == "remove") {
        player.remove(index);
    } else if (name == "clear") {
        player.clearUpcoming();
    } else if (name == "official") {
        music.playOfficial(player.current);
    }
}

/** 动作字符串保持原有输入协议，控制器直接更新原生音乐状态和场景。 */
void NativeHud::action(QString value) {
    auto &music = *m_music;
    const auto parts = value.split(':');
    if (value.startsWith("tab:")) {
        trackOffset = 0;
        bodyOffset = 0;
        tab = value.mid(4);
        if (music.current["kind"] == "song" && tab != "overview") {
            music.sameAlbum();
        }
        return;
    }
    if (value == "provider") {
        openModal("provider");
        return;
    }
    if (value.startsWith("provider:")) {
        const auto provider = value.mid(9);
        if (music.provider != provider) {
            ++m_searchGeneration;
            activeGroup.clear();
            query.clear();
            listOffset = 0;
            trackOffset = 0;
            music.switchProvider(provider);
        }
        return;
    }
    if (value == "confirm:yes") {
        const auto run = std::exchange(m_confirm, {});
        closeModal();
        if (run) {
            run();
        }
        return;
    }
    if (value.startsWith("discover:")) {
        auto &discover = *music.discover;
        const auto name = parts.value(1);
        if (name == "tab") {
            listOffset = 0;
            discover.load(parts.value(2));
            if (parts.value(2) == "categories" && discover.categories.isEmpty()) {
                discover.loadCategories();
            }
        } else if (name == "item") {
            discover.open(parts.value(2).toInt());
            closeModal();
        } else if (name == "category") {
            listOffset = 0;
            discover.category = decode(parts.value(2));
            discover.load("categories");
        } else if (name == "more") {
            discover.load(discover.tab, true);
        } else if (name == "prev" || name == "next") {
            const auto maximum = std::max(0, int(discover.items.size()) - 6);
            listOffset = std::clamp(listOffset + (name == "prev" ? -6 : 6), 0, maximum);
        }
        return;
    }
    if (value.startsWith("player:")) {
        playerAction(parts);
        return;
    }
    if (value == "open") {
        if (!music.current.isEmpty()) {
            if (music.current["kind"] != "song") {
                music.enterDirectory(music.current);
            } else {
                m_scene.mode("detail");
                music.loadSongWiki();
            }
        }
        return;
    }
    if (value == "back") {
        lyricsMode = false;
        if (music.directory) {
            if (frame["mode"] == "detail") {
                music.returnToDirectory();
            } else {
                music.leaveDirectory();
            }
            return;
        }
    }
    if ((value == "column-prev" || value == "column-next") && music.directory) {
        music.navigateDirectory(value == "column-next" ? 8 : -8);
        return;
    }
    if (value == "prev" || value == "next") {
        music.next(value == "next" ? 1 : -1);
        return;
    }
    if (value == "column-prev" || value == "column-next") {
        QVector<int> sources{0, 1, 2, 3, 4};
        if (music.provider == "kugou") {
            sources = {0, 1, 2, 3};
        }
        const auto index = sources.indexOf(music.selectedLane);
        music.showSource(sources.at(wrap(index + (value == "column-next" ? 1 : -1), sources.size())));
        return;
    }
    if (value.startsWith("music:")) {
        musicAction(parts, value);
        return;
    }
    if (value == "back") {
        music.observe(-1);
        music.observe(frame["selected"].toInt());
    }
    if (value.startsWith("viewer:")) {
        m_scene.viewer(value.mid(7));
        return;
    }
    if (value == "discover") {
        openModal("discover");
        music.discover->load();
    } else if (value == "skip" || value == "back") {
        m_scene.mode("archive");
    } else if (QStringList{"search", "saved", "settings"}.contains(value)) {
        openModal(value);
    } else if (value == "close-modal") {
        closeModal();
    } else if (value == "viewer") {
        m_scene.openViewer();
    } else if (value == "replay") {
        if (!modal.isEmpty()) {
            closeModal();
        }
        m_scene.mode("boot");
    } else if (value == "alternative") {
        music.player.alternative = !music.player.alternative;
        m_host->setPreference("alternate-source", music.player.alternative ? "on" : "off");
    } else if (value == "quality") {
        music.player.quality =
            cycle({"standard", "higher", "exhigh", "lossless", "hires", "jymaster"}, music.player.quality);
        m_host->setPreference("quality", music.player.quality);
    } else if (value == "theme") {
        themeMode = cycle({"light", "dark", "system"}, themeMode);
        dark = themeMode == "system" ? m_host->systemDark() : themeMode == "dark";
        m_scene.theme(dark);
        m_host->setPreference("theme", themeMode);
    } else if (value == "motion") {
        reduced = !reduced;
        m_scene.reduced(reduced);
        m_host->setPreference("motion", reduced ? "reduced" : "full");
    }
}

void NativeHud::key(QString value, bool command) {
    if (frame.isEmpty()) {
        return;
    }
    if (value == "Enter" && command) {
        m_music->play();
        return;
    }
    if (frame["viewer"].toBool()) {
        m_scene.viewerKey(value);
        return;
    }
    if (value == "Escape") {
        action(modal.isEmpty() ? "back" : "close-modal");
        return;
    }
    if (!modal.isEmpty()) {
        return;
    }
    if (value == " ") {
        m_music->player.toggle();
        return;
    }
    static const QHash<QString, QString> actions{{"ArrowLeft", "column-prev"},
                                                 {"ArrowRight", "column-next"},
                                                 {"ArrowUp", "prev"},
                                                 {"ArrowDown", "next"},
                                                 {"Enter", "open"},
                                                 {"/", "search"}};
    if (actions.contains(value)) {
        action(actions[value]);
    }
}

bool NativeHud::animating(double time) const {
    if (reduced) {
        return !motion.finished() || closing;
    }
    const bool lyrics = lyricsMode && modal.isEmpty() && m_lyricsCurve &&
                        time - m_lyricsCurve->start < m_lyricsCurve->duration;
    if (!motion.finished() || lyrics || closing || time - m_resultStart < 0.5) {
        return true;
    }
    return std::any_of(m_rolling.cbegin(), m_rolling.cend(),
                       [time](const auto &entry) { return entry.second.active(time); });
}
