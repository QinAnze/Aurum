#include "NativeHud.h"
#include "MusicData.h"
#include <QPointer>
#include <QUrl>
#include <algorithm>

namespace {
int wrap(int value, int count) {
    return count > 0 ? (value % count + count) % count : 0;
}
QString decode(QString value) {
    return QUrl::fromPercentEncoding(value.toUtf8());
}
}

/** 将音乐界面动作交给原生资料库；写入确认捕获账号代数，避免切换后修改另一个账号。 */
void NativeHud::musicAction(const QStringList &parts, const QString &value) {
    auto &music = *m_music;
    const auto name = parts.value(1);
    const auto last = parts.constLast().toInt();
    if (name == "slot") {
        const auto directory = music.directory;
        if (directory && !directory->songs.isEmpty()) {
            music.selectDirectory(
                wrap(directory->page + wrap(music.selectedLane * 8 + last - directory->anchor, 40),
                     directory->songs.size()));
            return;
        }
        const auto count = music.libraryItems().size();
        if (count > 0) {
            const auto index = wrap(music.offsets[music.selectedLane] + last, count);
            const auto raw = music.groupLane == music.selectedLane ? music.groupIndices.value(index) : index;
            music.selectResult(raw, music.selectedLane, false);
            m_scene.mode("archive");
        }
    } else if (name == "result") {
        music.selectResult(parts.value(3).toInt(), parts.value(2).toInt());
        tab = "overview";
        trackOffset = 0;
        bodyOffset = 0;
        closeModal();
    } else if (name == "track") {
        if (music.directory && last >= 0 && last < music.directory->songs.size()) {
            music.selectDirectory(last, "detail");
        } else if (last >= 0 && last < music.tracks.size()) {
            music.choose(music.tracks.at(last).toObject());
        }
        tab = "overview";
        trackOffset = 0;
        bodyOffset = 0;
    } else if (name == "parent") {
        music.leaveDirectory();
    } else if (name == "directory-more") {
        if (music.directory) {
            music.loadDirectoryPage();
        } else {
            music.loadTrackPage(trackOffset);
        }
    } else if (name == "directory-info") {
        music.showDirectoryInfo();
        trackOffset = 0;
    } else if (name == "directory") {
        if (music.directory) {
            music.returnToDirectory();
        } else if (!music.current.isEmpty()) {
            music.enterDirectory(music.current);
        }
    } else if (name == "first-track") {
        if (trackOffset >= 0 && trackOffset < music.tracks.size()) {
            music.choose(music.tracks.at(trackOffset).toObject());
        }
        tab = "overview";
        trackOffset = 0;
        bodyOffset = 0;
    } else if (name == "hint") {
        query = decode(value.mid(11));
        listOffset = 0;
        music.search(query);
    } else if (name == "kind") {
        ++m_searchGeneration;
        listOffset = 0;
        activeGroup.clear();
        const auto kind = QStringList{"song", "album", "playlist", "artist"}.value(last, "song");
        const auto text = query.isEmpty() ? music.keyword : query;
        if (text.isEmpty()) {
            music.searchKind = kind;
        } else {
            music.search(text, kind);
        }
    } else if (name == "group") {
        music.setGroupView({}, {}, modal == "saved" ? musicCollection : 0);
        ++m_searchGeneration;
        groupBy = QStringList{"none", "artist", "album"}.value(last, "none");
        activeGroup.clear();
        listOffset = 0;
    } else if (name == "expand") {
        ++m_searchGeneration;
        const auto lane = modal == "saved" ? musicCollection : 0;
        const auto key = decode(value.mid(13));
        const auto groups = rows(lane);
        const auto group = std::find_if(groups.cbegin(), groups.cend(),
                                        [&key](const Row &row) { return row.value["key"] == key; });
        activeGroup = key;
        listOffset = 0;
        if (group != groups.cend()) {
            music.setGroupView(group->value["title"].toString(), group->indices, lane);
        }
    } else if (name == "group-back") {
        music.setGroupView({}, {}, modal == "saved" ? musicCollection : 0);
        ++m_searchGeneration;
        activeGroup.clear();
        listOffset = 0;
    } else if (name == "artist") {
        music.openSongArtist(last);
        artistTab = "songs";
    } else if (name == "artist-tab") {
        artistTab = parts.value(2);
        trackOffset = 0;
        if (artistTab == "albums") {
            music.loadArtistAlbums();
        }
    } else if (name == "artist-album") {
        if (music.directory && last >= 0 && last < music.directory->albums.size()) {
            music.enterDirectory(music.directory->albums.at(last).toObject());
        }
        artistTab = "songs";
    } else if (name == "artist-more") {
        music.loadArtistAlbums();
    } else if (name == "collection") {
        if (last < 0 || last >= 5) {
            return;
        }
        activeGroup.clear();
        ++m_searchGeneration;
        musicCollection = last;
        listOffset = 0;
        if (music.lists[last].isEmpty()) {
            music.loadMoreSource(last);
        }
    } else if (name == "more") {
        if (last >= 0 && last < 5) {
            music.loadMoreSource(last);
        }
    } else if (name == "page-prev" || name == "page-next") {
        pageResults(name == "page-prev" ? -1 : 1);
    } else if (name == "play") {
        music.play();
    } else if (name == "play-next" || name == "enqueue") {
        music.player.enqueue(music.current, name == "play-next");
    } else if (name == "play-loaded") {
        music.playDirectory();
    } else if (name == "remove-track") {
        if (music.directory) {
            music.playlistTrack(music.directory->item["id"].toString(), music.current, true);
        }
    } else if (name == "picker-prev" || name == "picker-next") {
        const auto maximum = std::max(0, int(music.lists[2].size()) - 7);
        listOffset = std::clamp(listOffset + (name == "picker-prev" ? -7 : 7), 0, maximum);
    } else if (name == "official") {
        music.playOfficial();
    } else if (name == "copy") {
        if (!music.current.isEmpty()) {
            m_host->copy(music.current["id"].toString());
            music.status = "已复制" + music.providerName() + " ID";
            music.changed();
        }
    } else if (name == "source") {
        if (!music.current.isEmpty()) {
            m_host->open(music.sourceURL());
        }
    } else if (name.startsWith("project-")) {
        static const QHash<QString, QString> links{
            {"project-home", "https://github.com/MikeQu223/Rhine-Music-Database"},
            {"project-author", "https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced"},
            {"project-player", "https://github.com/yakult-green-tea/qq-music-api"},
            {"project-kugou", "https://github.com/MakcRe/KuGouMusicApi"},
            {"project-rhine", "https://github.com/LBEILC/RhineLabUI"},
            {"project-lyricsx", "https://github.com/MxIris-LyricsX-Project/LyricsX"},
            {"project-lyricskit", "https://github.com/MxIris-LyricsX-Project/LyricsKit"},
            {"project-lyrimuse", "https://github.com/Yudaotor/lyrimuse"}};
        if (links.contains(name)) {
            m_host->open(links[name]);
        }
    } else if (name == "login") {
        openModal("login");
        music.loginMethod = "qr";
        music.startLogin();
    } else if (name == "kugou-edition") {
        const QPointer<NativeHud> owner(this);
        const auto token = m_searchGeneration;
        music.switchProvider("kugou", parts.value(2), [owner, token](bool ok) {
            if (ok && owner && owner->modal == "login" && owner->m_searchGeneration == token) {
                owner->m_music->startLogin();
            }
        });
    } else if (name == "login-method") {
        music.cancelLogin();
        music.loginMethod = parts.value(2);
        music.loginStatus.clear();
        if (QStringList{"qr", "wechat"}.contains(music.loginMethod)) {
            music.startLogin();
        }
    } else if (name == "like" || name == "like-current") {
        music.like(name == "like" ? QJsonObject() : music.player.current);
    } else if (name == "subscribe") {
        music.subscribe();
    } else if (name == "create-playlist") {
        formKind = "create";
        formPID.clear();
        openModal("playlist-form");
    } else if (name == "delete-playlist") {
        if (!music.directory || music.uid.isEmpty() || music.directory->item["creatorID"] != music.uid) {
            return;
        }
        const auto item = music.directory->item;
        confirmTitle = "删除歌单：" + item["title"].toString();
        const QPointer<MusicLibrary> owner(&music);
        const auto generation = music.accountGeneration();
        m_confirm = [owner, generation, item]() {
            if (!owner || owner->accountGeneration() != generation) {
                return;
            }
            owner->mutate("/playlist/delete", {{"id", item["id"]}}, [owner, item](QJsonObject) {
                if (!owner) {
                    return;
                }
                QJsonArray values;
                for (const auto &entry : owner->lists[2]) {
                    if (entry.toObject()["id"] != item["id"]) {
                        values.append(entry);
                    }
                }
                owner->lists[2] = values;
                owner->totals[2] = values.size();
                owner->leaveDirectory();
            });
        };
        openModal("confirm");
    } else if (name == "rename-playlist") {
        if (music.directory && music.directory->item["creatorID"] == music.uid) {
            formKind = "rename";
            formPID = music.directory->item["id"].toString();
            openModal("playlist-form");
        }
    } else if (name == "add-to-playlist") {
        openModal("playlist-picker");
        if (music.lists[2].isEmpty()) {
            music.loadMoreSource(2);
        }
    } else if (name == "playlist-pick") {
        const QPointer<NativeHud> owner(this);
        const auto token = m_searchGeneration;
        music.playlistTrack(parts.value(2), {}, false, [owner, token](bool ok) {
            if (ok && owner && owner->m_searchGeneration == token && owner->modal == "playlist-picker") {
                owner->closeModal();
            }
        });
    } else if (name == "qr") {
        music.startLogin();
    } else if (name == "logout") {
        music.logout();
    } else if (name == "cover-front" || name == "cover-back") {
        m_scene.coverFront(name == "cover-front");
    } else if (name == "activate") {
        m_host->setActivates(!m_host->activates());
    }
}
