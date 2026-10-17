#include "MusicLibrary.h"
#include "MusicData.h"
#include <QRegularExpression>
#include <algorithm>
#include <cmath>

/** 先建立可返回的目录状态，再加载内容；目录关闭或被替换后丢弃旧响应。 */
void MusicLibrary::enterDirectory(QJsonObject value) {
    if (value.isEmpty()) {
        return;
    }
    if (value["kind"] == "song") {
        choose(value);
        return;
    }
    const auto token = ++m_directoryGeneration;
    ++m_selectionGeneration;
    ++m_wikiGeneration;
    const auto physical = selectedPhysical >= 0
                              ? selectedPhysical
                              : frame["selected"].toInt(physicalSlots[selectedLane].value(0, -1));
    auto next = std::make_shared<MusicDirectory>();
    next->parent = directory;
    next->item = value;
    next->albumsMore = value["kind"] == "artist";
    next->parentPhysical = physical;
    next->parentLane = selectedLane;
    next->parentItem = value;
    directory = next;
    directoryInfo = false;
    directoryLoading = true;
    wantsSongDetails = false;
    current = {};
    tracks = {};
    trackIDs = {};
    coverImage.clear();
    coverKey.clear();
    detailLoading = false;
    emit modeRequested("archive");
    emit navigationRequested("lane", 1);
    const auto destination = (selectedLane + 1) % 5;
    next->anchor = destination * 8 + rowMemory[destination];
    selectedPhysical = -1;
    status = QStringLiteral("正在打开：") + value["title"].toString();
    changed();
    api.call(
        "detail", {value},
        [this, next, value](MusicReply result) {
            if (!result.ok()) {
                directoryLoading = false;
                status = QStringLiteral("读取失败：") + result.error;
                changed();
                return;
            }
            const auto values = result.value.toArray();
            next->item = values.at(0).toObject();
            next->songs = values.at(1).toArray();
            next->ids = values.at(2).toArray();
            next->cursor = MusicData::cursor(next->songs, next->ids);
            details[next->item["key"].toString()] = next->item;
            directoryLoading = false;
            status = QStringLiteral("已打开：") + next->item["title"].toString();
            if (value["kind"] == "artist") {
                showDirectoryInfo();
            } else if (!next->songs.isEmpty()) {
                next->index = 0;
                choose(next->songs.first().toObject());
            } else {
                changed();
            }
        },
        valid(token, &m_directoryGeneration));
}

void MusicLibrary::loadArtistAlbums() {
    const auto folder = directory;
    if (!folder || folder->item["kind"] != "artist" || folder->albumsLoading || !folder->albumsMore) {
        return;
    }
    folder->albumsLoading = true;
    changed();
    api.call(
        "artistAlbums", {folder->item["id"], folder->albumCursor},
        [this, folder](MusicReply result) {
            if (result.ok()) {
                const auto page = result.value.toObject();
                folder->albums = MusicData::unique(folder->albums, page["items"].toArray());
                folder->albumCursor += page["rawCount"].toInt();
                folder->albumsMore = page["more"].toBool();
            } else {
                status = QStringLiteral("专辑读取失败：") + result.error;
            }
            folder->albumsLoading = false;
            changed();
        },
        valid(m_directoryGeneration, &m_directoryGeneration));
}

void MusicLibrary::openSongArtist(int index) {
    const auto artists = current["artists"].toArray();
    const auto artist = artists.at(index).toObject();
    static const QRegularExpression identifier(QStringLiteral("^[a-zA-Z0-9_-]{1,80}$"));
    if (!artist.isEmpty() && identifier.match(artist["id"].toString()).hasMatch()) {
        enterDirectory(
            MusicData::item("artist", artist["id"].toString(), artist["name"].toString(), {}, provider));
    }
}

void MusicLibrary::observeDirectory(int physical) {
    const auto folder = directory;
    if (!folder || directoryInfo || selectedPhysical == physical) {
        return;
    }
    int lane = -1;
    for (int i = 0; i < 5; ++i) {
        if (physicalSlots[i].contains(physical)) {
            lane = i;
            break;
        }
    }
    if (lane < 0) {
        return;
    }
    const auto row = int(physicalSlots[lane].indexOf(physical));
    selectedPhysical = physical;
    selectedLane = lane;
    if (folder->songs.isEmpty()) {
        folder->anchor = lane * 8 + row;
        return;
    }
    folder->index = (folder->page + ((lane * 8 + row - folder->anchor + 40) % 40)) % folder->songs.size();
    choose(folder->songs.at(folder->index).toObject());
}

void MusicLibrary::selectDirectory(int index, QString mode, QString axis, int direction) {
    if (!directory || index < 0 || index >= directory->songs.size()) {
        return;
    }
    directoryInfo = false;
    directory->index = index;
    directory->page = index / 40 * 40;
    const auto cell = (index + directory->anchor) % 40;
    selectedLane = cell / 8;
    const auto physical = physicalSlots[selectedLane].value(cell % 8, -1);
    const auto navigation =
        axis.isEmpty() ? QJsonObject{} : QJsonObject{{"axis", axis}, {"direction", direction}};
    emit selectionRequested(physical, navigation);
    selectedPhysical = physical;
    choose(directory->songs.at(index).toObject(), false, mode == "detail");
    emit modeRequested(mode);
    changed();
}

void MusicLibrary::navigateDirectory(int step, QString axis) {
    const auto folder = directory;
    if (!folder || folder->songs.isEmpty()) {
        return;
    }
    const auto target = folder->index + step;
    if (target >= folder->songs.size() && folder->cursor < folder->ids.size()) {
        loadDirectoryPage(target);
        return;
    }
    int direction = step > 0 ? 1 : -1;
    if (axis == "row") {
        direction = step;
    }
    if (axis.isEmpty()) {
        axis = std::abs(step) > 1 ? "lane" : "row";
    }
    const auto count = int(folder->songs.size());
    selectDirectory(((target % count) + count) % count, "archive", axis, direction);
}

/** 按完整 ID 分页补齐曲目，游标按已消费 ID 数推进，无法播放的条目不会重复请求。 */
void MusicLibrary::loadDirectoryPage(std::optional<int> selectAfter) {
    const auto folder = directory;
    if (!folder || directoryLoading || folder->cursor >= folder->ids.size()) {
        return;
    }
    directoryLoading = true;
    const auto ids = MusicData::slice(folder->ids, folder->cursor, 100);
    changed();
    api.call(
        "songs", {QJsonValue(ids)},
        [this, folder, ids, selectAfter](MusicReply result) {
            directoryLoading = false;
            if (!result.ok()) {
                status = result.error;
                changed();
                return;
            }
            folder->songs = MusicData::unique(folder->songs, MusicData::ordered(ids, result.value.toArray()));
            folder->cursor += ids.size();
            if (selectAfter && *selectAfter >= 0 && *selectAfter < folder->songs.size()) {
                selectDirectory(*selectAfter);
            } else {
                changed();
            }
        },
        valid(m_directoryGeneration, &m_directoryGeneration));
}

void MusicLibrary::showDirectoryInfo() {
    if (!directory) {
        return;
    }
    ++m_selectionGeneration;
    directoryInfo = true;
    current = directory->item;
    detailLoading = false;
    tracks = directory->songs;
    trackIDs = directory->ids;
    coverImage.clear();
    coverKey.clear();
    emit musicIdentityRequested(directory->item["key"].toString());
    loadCover(directory->item);
    emit modeRequested("detail");
    changed();
}

void MusicLibrary::returnToDirectory() {
    if (directory) {
        if (directory->songs.isEmpty()) {
            leaveDirectory();
            return;
        }
        selectDirectory(directory->index);
    }
    changed();
}

void MusicLibrary::leaveDirectory(bool restore) {
    const auto folder = directory;
    if (!folder) {
        return;
    }
    ++m_directoryGeneration;
    directory = restore ? folder->parent : nullptr;
    directoryLoading = false;
    directoryInfo = false;
    ++m_selectionGeneration;
    ++m_wikiGeneration;
    tracks = {};
    trackIDs = {};
    coverImage.clear();
    coverKey.clear();
    detailLoading = false;
    if (restore) {
        selectedLane = folder->parentLane;
        selectedPhysical = folder->parentPhysical;
        current = details.value(folder->item["key"].toString(), folder->parentItem);
        emit selectionRequested(folder->parentPhysical, {{"axis", "lane"}, {"direction", -1}});
        emit modeRequested("archive");
        if (directory) {
            selectDirectory(directory->index);
            status = QStringLiteral("已返回：") + directory->item["title"].toString();
            changed();
            return;
        }
        if (!current.isEmpty()) {
            emit musicIdentityRequested(current["key"].toString());
            loadCover(current);
        }
    }
    status = QStringLiteral("已返回：") + columns.value(selectedLane);
    changed();
}

/** 切歌沿用原物理选中与取出顺序，队列外曲目建立可返回的播放队列目录。 */
void MusicLibrary::followPlayback(QJsonObject value) {
    if (current["key"] == value["key"] && current["id"] == value["id"]) {
        return;
    }
    const auto previous = current;
    const auto physical = selectedPhysical >= 0
                              ? selectedPhysical
                              : frame["selected"].toInt(physicalSlots[selectedLane].value(0, -1));
    auto folder = directory;
    auto index = folder ? MusicData::indexOfId(folder->songs, value["id"].toString()) : -1;
    if (index < 0) {
        ++m_directoryGeneration;
        directoryLoading = false;
        folder = std::make_shared<MusicDirectory>();
        folder->parent = directory;
        folder->item = {{"kind", "playlist"},
                        {"key", "playback:queue"},
                        {"id", ""},
                        {"title", "播放队列"},
                        {"trackCount", player.queue.size()}};
        folder->songs = player.queue;
        for (const auto &song : player.queue) {
            folder->ids.append(song.toObject()["id"]);
        }
        folder->cursor = int(player.queue.size());
        index = MusicData::indexOfId(player.queue, value["id"].toString());
        folder->index = index;
        const auto row = std::max(0, int(physicalSlots[selectedLane].indexOf(physical)));
        folder->anchor = selectedLane * 8 + row;
        folder->parentPhysical = physical;
        folder->parentLane = selectedLane;
        folder->parentItem = previous;
        directory = folder;
    }
    if (index < 0 || index >= folder->songs.size()) {
        return;
    }
    folder->songs.replace(index, value);
    const auto cell = (index + folder->anchor) % 40;
    const auto target = physicalSlots[cell / 8].value(cell % 8, -1);
    selectDirectory(index, "detail", target == physical ? "row" : "", target == physical ? 8 : 1);
    if (!frame.isEmpty()) {
        frame["mode"] = "detail";
    }
}
