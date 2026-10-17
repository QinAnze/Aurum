#include "MusicLibrary.h"
#include "MusicData.h"
#include "MusicDiscover.h"
#include <QJsonDocument>
#include <QPointer>
#include <QUrl>
#include <algorithm>

namespace {
int wrap(int value, int count) {
    return ((value % count) + count) % count;
}
}

/** 建立原生资料库和各类请求的独立代数，物理槽位保持原有五列八行映射。 */
MusicLibrary::MusicLibrary(Host *host, const QJsonObject &content, QObject *parent)
    : QObject(parent), host(host), api(host), player(host, &api), m_identityApi(host) {
    kugouEdition = host->preference("kugou-edition") == "lite" ? "lite" : "standard";
    provider = host->preference("provider");
    if (!QStringList{"netease", "qq", "kugou"}.contains(provider)) {
        provider = "netease";
    }
    api.provider = provider;
    host->setProvider(provider);
    for (const auto &source : {"netease", "qq"}) {
        identityNames[source] = host->preference("welcome-name-" + QString::fromUtf8(source));
    }
    identityNames["kugou"] = host->preference("welcome-name-kugou-" + kugouEdition);
    restoreCachedAccount();
    const auto categories = content["columns"].toArray();
    const auto records = content["records"].toArray();
    for (int lane = 0; lane < 5 && lane < categories.size(); ++lane) {
        for (qsizetype i = 0; i < records.size(); ++i) {
            if (records.at(i).toObject()["category"] == categories.at(lane)) {
                physicalSlots[lane].append(int(i));
            }
        }
    }
    const auto saved = QJsonDocument::fromJson(host->preference("search-history").toUtf8()).array();
    for (const auto &value : saved) {
        if (value.isString() && searchHistory.size() < 12) {
            searchHistory.append(value.toString());
        }
    }
    discover = std::make_unique<MusicDiscover>(this);
    connect(&player, &MusicPlayer::changed, this, &MusicLibrary::changed);
    connect(&player, &MusicPlayer::trackSelected, this, &MusicLibrary::followPlayback);
}

MusicLibrary::~MusicLibrary() = default;

MusicApi::Valid MusicLibrary::valid(quint64 token, const quint64 *counter) {
    return [owner = QPointer(this), token, counter] { return owner && *counter == token; };
}

void MusicLibrary::changed() {
    ++revision;
    emit invalidated();
}

QString MusicLibrary::providerName() const {
    if (provider == "kugou" && kugouEdition == "lite") {
        return QStringLiteral("酷狗概念版");
    }
    return MusicApi::providerName(provider);
}

QString MusicLibrary::accountKey() const {
    return provider == "kugou" ? "kugou-" + kugouEdition : provider;
}

QString MusicLibrary::identityName() const {
    for (const auto &source : {"netease", "qq", "kugou"}) {
        if (!identityNames.value(source).isEmpty()) {
            return identityNames.value(source);
        }
    }
    return {};
}

QString MusicLibrary::libraryName() const {
    if (directory) {
        return directory->item["title"].toString();
    }
    return groupLane == selectedLane ? groupName : columns.value(selectedLane);
}

QJsonArray MusicLibrary::sourceItems(int lane) const {
    if (lane < 0 || lane >= 5) {
        return {};
    }
    if (groupLane != lane) {
        return lists[lane];
    }
    QJsonArray result;
    for (const auto index : groupIndices) {
        if (index >= 0 && index < lists[lane].size()) {
            result.append(lists[lane].at(index));
        }
    }
    return result;
}

QJsonArray MusicLibrary::libraryItems() const {
    return directory ? directory->songs : sourceItems(selectedLane);
}

int MusicLibrary::libraryTotal() const {
    if (directory) {
        return std::max({int(directory->ids.size()), directory->item["trackCount"].toInt(),
                         int(directory->songs.size())});
    }
    return groupLane == selectedLane ? int(sourceItems(selectedLane).size()) : totals[selectedLane];
}

int MusicLibrary::libraryIndex() const {
    if (directory) {
        return directory->index;
    }
    const auto row = std::max(0, int(physicalSlots[selectedLane].indexOf(selectedPhysical)));
    return wrap(offsets[selectedLane] + row, std::max(1, int(sourceItems(selectedLane).size())));
}

void MusicLibrary::setGroupView(QString name, QVector<int> indices, int lane) {
    if (lane < 0 || lane >= 5) {
        return;
    }
    groupName = name;
    groupIndices = indices;
    groupLane = name.isEmpty() ? -1 : lane;
    offsets[lane] = 0;
    rowMemory[lane] = 0;
    showSource(lane);
}

void MusicLibrary::observe(int selected) {
    if (directory) {
        observeDirectory(selected);
        return;
    }
    if (selectedPhysical == selected) {
        return;
    }
    int lane = -1;
    for (int i = 0; i < 5; ++i) {
        if (physicalSlots[i].contains(selected)) {
            lane = i;
            break;
        }
    }
    if (lane < 0) {
        return;
    }
    if (provider == "kugou" && lane == 4) {
        if (!physicalSlots[selectedLane].isEmpty()) {
            emit selectionRequested(physicalSlots[selectedLane].value(rowMemory[selectedLane]), {});
        }
        return;
    }
    selectedPhysical = selected;
    const auto row = int(physicalSlots[lane].indexOf(selected));
    selectedLane = lane;
    rowMemory[lane] = row;
    const auto values = sourceItems(lane);
    choose(values.isEmpty() ? QJsonObject{} : values.at(wrap(offsets[lane] + row, values.size())).toObject());
}

/** 先发布当前选择，再延迟补齐详情；任何旧详情、封面或百科都由选择代数隔离。 */
void MusicLibrary::choose(QJsonObject input, bool containerDetails, std::optional<bool> showDetails) {
    const auto token = ++m_selectionGeneration;
    ++m_wikiGeneration;
    wantsSongDetails = showDetails.value_or(frame["mode"] == "detail");
    albumLoaded = false;
    trackCursor = 0;
    trackLoad = false;
    current = input;
    emit musicIdentityRequested(input["key"].toString());
    tracks = {};
    trackIDs = {};
    if (coverKey != input["key"].toString()) {
        coverImage.clear();
        coverKey.clear();
    }
    detailLoading = !input.isEmpty();
    changed();
    if (input.isEmpty()) {
        return;
    }
    current = details.value(input["key"].toString(), input);
    loadCover(current);
    detailLoading = true;
    if (input["kind"] != "song" && !containerDetails) {
        detailLoading = false;
        changed();
        return;
    }
    if (input["kind"] == "song" && current["duration"].toDouble() > 0 &&
        !current["albumID"].toString().isEmpty() &&
        (!current["cover"].toString().isEmpty() || details.contains(input["key"].toString()))) {
        details[input["key"].toString()] = current;
        detailLoading = false;
        if (wantsSongDetails) {
            loadSongWiki();
        }
        changed();
        return;
    }
    const auto alive = valid(token, &m_selectionGeneration);
    host->schedule(300, [this, input, alive] {
        if (!alive()) {
            return;
        }
        api.call(
            "detail", {input},
            [this, input, alive](MusicReply result) {
                const auto values = result.value.toArray();
                if (!result.ok() || values.isEmpty()) {
                    detailLoading = false;
                    status = QStringLiteral("读取失败：") +
                             (result.ok() ? QStringLiteral("元数据格式无效") : result.error);
                    changed();
                    return;
                }
                auto value = values.at(0).toObject();
                if (value["kind"] == "song") {
                    value["description"] = current.value("description").isUndefined()
                                               ? value["description"]
                                               : current["description"];
                    value["wiki"] = current["wiki"].toString();
                }
                if (!current["date"].toString().isEmpty()) {
                    value["date"] = current["date"];
                }
                details[input["key"].toString()] = value;
                for (qsizetype i = 0; i < lists[0].size(); ++i) {
                    if (lists[0].at(i).toObject()["key"] == input["key"]) {
                        lists[0].replace(i, value);
                        break;
                    }
                }
                current = value;
                const auto songs = values.at(1).toArray();
                if (value["kind"] != "song" || !albumLoaded) {
                    tracks = songs;
                }
                trackIDs = values.at(2).toArray();
                trackCursor = MusicData::cursor(songs, trackIDs);
                detailLoading = false;
                if (status == "正在读取链接…") {
                    status = QStringLiteral("已读取：") + value["title"].toString();
                }
                loadCover(value);
                changed();
                if (value["kind"] == "song" && value["wiki"].toString().isEmpty() && wantsSongDetails) {
                    api.call(
                        "wiki", {value["id"]},
                        [this, input](MusicReply wiki) {
                            current["wiki"] = wiki.ok() ? wiki.value.toString()
                                                        : QStringLiteral("百科暂时无法读取：") + wiki.error;
                            if (wiki.ok()) {
                                details[input["key"].toString()] = current;
                            }
                            changed();
                        },
                        alive);
                }
            },
            alive);
    });
}

void MusicLibrary::loadCover(const QJsonObject &value) {
    const auto alive = valid(m_selectionGeneration, &m_selectionGeneration);
    host->schedule(200, [this, value, alive] {
        if (alive()) {
            host->loadCover(value["cover"].toString(), [this, value, alive](QString key) {
                if (alive()) {
                    coverImage = key;
                    coverKey = value["key"].toString();
                    changed();
                }
            });
        }
    });
}

void MusicLibrary::search(QString text, QString kind, bool more) {
    const auto link = provider == "netease" && !more ? host->fromLink(text) : QString();
    if (!link.isEmpty()) {
        const auto type = link.section(':', 0, 0);
        const auto value = MusicData::item(type, link.section(':', 1));
        ++m_generation;
        searchLoading = false;
        keyword = text;
        searchKind = type;
        lists[0] = {value};
        totals[0] = 1;
        offsets[0] = 0;
        hasMore[0] = false;
        rowMemory[0] = 0;
        status = QStringLiteral("正在读取链接…");
        showSource(0);
        wantsSongDetails = type == "song";
        emit modeRequested(type == "song" ? "detail" : "archive");
        return;
    }
    const auto query = text.trimmed();
    if (!more && query == keyword && (kind.isEmpty() || kind == searchKind) &&
        (!lists[0].isEmpty() || searchLoading)) {
        return;
    }
    if (query.isEmpty() || query.toUcs4().size() > 100) {
        ++m_generation;
        searchLoading = false;
        status = QStringLiteral("请输入 1–100 字关键词");
        changed();
        return;
    }
    if (more && (searchLoading || !hasMore[0])) {
        return;
    }
    if (!kind.isEmpty()) {
        searchKind = kind;
    }
    keyword = query;
    const auto token = ++m_generation;
    const auto start = more ? searchCursor : 0;
    if (!more) {
        groupLane = -1;
        groupName.clear();
        groupIndices.clear();
        lists[0] = {};
        totals[0] = 0;
        offsets[0] = 0;
        searchCursor = 0;
        hasMore[0] = false;
        searchHistory.removeAll(query);
        searchHistory.prepend(query);
        while (searchHistory.size() > 12) {
            searchHistory.removeLast();
        }
        host->setPreference(
            "search-history",
            QString::fromUtf8(
                QJsonDocument(QJsonArray::fromStringList(searchHistory)).toJson(QJsonDocument::Compact)));
    }
    searchLoading = true;
    status = QStringLiteral("正在检索…");
    changed();
    api.call(
        "search", {query, searchKind, start},
        [this, start, more](MusicReply result) {
            searchLoading = false;
            if (!result.ok()) {
                status = QStringLiteral("检索失败：") + result.error;
                changed();
                return;
            }
            const auto page = result.value.toObject();
            const auto items = page["items"].toArray();
            lists[0] = more ? MusicData::unique(lists[0], items) : items;
            if (!more) {
                offsets[0] = 0;
            }
            searchCursor = start + page["rawCount"].toInt();
            hasMore[0] = page["more"].toBool();
            totals[0] = std::max(page["total"].toInt(), int(lists[0].size()));
            status = page["notice"].toString();
            if (status.isEmpty()) {
                status = items.isEmpty() ? QStringLiteral("没有匹配的音乐")
                                         : QStringLiteral("找到 ") + QString::number(totals[0]) +
                                               QStringLiteral(" 条结果");
            }
            if (!more) {
                showSource(0);
                emit modeRequested("archive");
                frame["mode"] = "archive";
            }
            changed();
        },
        valid(token, &m_generation));
}

void MusicLibrary::suggest(QString text) {
    const auto token = ++m_suggestGeneration;
    suggestions.clear();
    if (text.trimmed().isEmpty() || provider == "kugou") {
        return;
    }
    const auto qq = provider == "qq";
    api.request(
        qq ? "/getSmartbox" : "/search/suggest",
        qq ? QJsonObject{{"key", text}} : QJsonObject{{"keywords", text}, {"type", "mobile"}},
        [this, qq](MusicReply result) {
            if (!result.ok()) {
                return;
            }
            const auto body = result.value.toObject();
            const auto values =
                qq ? body["response"].toObject()["data"].toObject()["song"].toObject()["itemlist"].toArray()
                   : body["result"].toObject()["allMatch"].toArray();
            for (const auto &value : values) {
                const auto keyword = value.toObject()[qq ? "name" : "keyword"];
                if (keyword.isString() && suggestions.size() < 4) {
                    suggestions.append(keyword.toString());
                }
            }
        },
        valid(token, &m_suggestGeneration));
}

void MusicLibrary::showSource(int lane) {
    if (lane < 0 || lane >= 5) {
        return;
    }
    if (provider == "kugou" && lane == 4) {
        status = QStringLiteral("酷狗 API 未提供收藏专辑，此栏目已禁用");
        changed();
        return;
    }
    privateSelection = lane > 0;
    if (directory) {
        leaveDirectory(false);
    }
    selectedLane = lane;
    selectedPhysical = -1;
    const auto physical = physicalSlots[lane].value(rowMemory[lane], -1);
    emit selectionRequested(physical, {});
    observe(physical);
    if (lane > 0) {
        if (uid.isEmpty()) {
            status = QStringLiteral("登录后查看") + columns[lane];
        } else if (lists[lane].isEmpty()) {
            loadMoreSource(lane);
        }
    }
    changed();
}

void MusicLibrary::selectResult(int index, int lane, bool open) {
    if (lane < 0 || lane >= 5 || index < 0 || index >= lists[lane].size()) {
        return;
    }
    if (directory) {
        leaveDirectory(false);
    }
    auto viewIndex = index;
    if (groupLane == lane) {
        viewIndex = groupIndices.indexOf(index);
        if (viewIndex < 0) {
            groupLane = -1;
            viewIndex = index;
        }
    }
    offsets[lane] = viewIndex / 8 * 8;
    selectedPhysical = -1;
    const auto physical = physicalSlots[lane].value(viewIndex % 8, -1);
    emit selectionRequested(physical, {});
    const auto mode = open && lists[lane].at(index).toObject()["kind"] == "song" ? "detail" : "archive";
    emit modeRequested(mode);
    frame["mode"] = mode;
    observe(physical);
    if (open && current["kind"] != "song") {
        enterDirectory(current);
    }
}

void MusicLibrary::next(int direction) {
    if (directory) {
        navigateDirectory(direction, "row");
        return;
    }
    const auto row = int(physicalSlots[selectedLane].indexOf(selectedPhysical));
    const auto count = int(sourceItems(selectedLane).size());
    if (row < 0 || count == 0) {
        return;
    }
    const auto absolute = wrap(offsets[selectedLane] + row, count);
    const auto raw = absolute + direction;
    if (raw >= count && hasMore[selectedLane] && groupLane != selectedLane) {
        loadMoreSource(selectedLane);
        return;
    }
    const auto next = wrap(raw, count);
    const auto target = wrap(row + direction, 8);
    offsets[selectedLane] = next - target;
    emit navigationRequested("row", direction);
    selectedPhysical = -1;
    changed();
}

void MusicLibrary::completePersonal(int lane) {
    personalLoading = false;
    status = QStringLiteral("已读取个人音乐");
    if (selectedLane == lane && current.isEmpty()) {
        selectedPhysical = -1;
        observe(frame["selected"].toInt(physicalSlots[lane].value(0, -1)));
    }
    changed();
}

void MusicLibrary::loadLikedIDs(int lane, quint64 token, QString user) {
    const auto alive = valid(token, &m_accountGeneration);
    const auto fetch = [this, lane, user, alive](QJsonArray ids) {
        const auto chunk = MusicData::slice(ids, likedCursor, 100);
        api.call(
            "songs", {QJsonValue(chunk)},
            [this, lane, user, ids, chunk](MusicReply result) {
                if (uid != user) {
                    return;
                }
                if (!result.ok()) {
                    personalLoading = false;
                    status = result.error;
                    changed();
                    return;
                }
                likedIDs = ids;
                likedCursor += chunk.size();
                lists[1] = MusicData::unique(lists[1], MusicData::ordered(chunk, result.value.toArray()));
                totals[1] = int(ids.size());
                hasMore[1] = likedCursor < ids.size();
                completePersonal(lane);
            },
            alive);
    };
    if (likedIDs) {
        fetch(*likedIDs);
    } else {
        api.call(
            "likedIDs", {user},
            [this, fetch](MusicReply result) {
                if (!result.ok()) {
                    personalLoading = false;
                    status = result.error;
                    changed();
                    return;
                }
                fetch(result.value.toArray());
            },
            alive);
    }
}

void MusicLibrary::loadMoreSource(int lane) {
    if (lane < 0 || lane >= 5) {
        return;
    }
    if (provider == "kugou" && lane == 4) {
        hasMore[4] = false;
        status = QStringLiteral("酷狗 API 未提供收藏专辑，此栏目已禁用");
        changed();
        return;
    }
    if (personalLoading || !hasMore[lane]) {
        return;
    }
    if (lane == 0) {
        search(keyword, {}, true);
        return;
    }
    if (uid.isEmpty()) {
        status = QStringLiteral("请登录") + providerName();
        changed();
        return;
    }
    personalLoading = true;
    const auto token = m_accountGeneration;
    const auto user = uid;
    changed();
    if (lane == 1 && provider == "netease") {
        loadLikedIDs(lane, token, user);
        return;
    }
    QString operation;
    QJsonArray arguments;
    if (lane == 1) {
        operation = "likedSongs";
        arguments = {likedCursor};
    } else if (lane == 4) {
        operation = "likedAlbums";
        arguments = {albumCursor};
    } else {
        operation = "userPlaylists";
        arguments = {user};
    }
    api.call(
        operation, arguments,
        [this, lane, user](MusicReply result) {
            if (uid != user) {
                return;
            }
            if (!result.ok()) {
                personalLoading = false;
                status = result.error;
                changed();
                return;
            }
            const auto page = result.value.toObject();
            const auto items = page["items"].toArray();
            if (lane == 1) {
                likedCursor += page["rawCount"].toInt();
                lists[1] = MusicData::unique(lists[1], items);
                QJsonArray ids;
                for (const auto &value : lists[1]) {
                    ids.append(value.toObject()["id"]);
                }
                likedIDs = ids;
                totals[1] = page["total"].toInt();
                hasMore[1] = page["more"].toBool();
            } else if (lane == 4) {
                albumCursor += page["rawCount"].toInt();
                lists[4] = MusicData::unique(lists[4], items);
                totals[4] = std::max(page["total"].toInt(), int(lists[4].size()));
                hasMore[4] = page["more"].toBool();
            } else {
                playlistCursor += page["rawCount"].toInt();
                QJsonArray owned;
                QJsonArray collected;
                for (const auto &value : items) {
                    if (value.toObject()["creatorID"] == user) {
                        owned.append(value);
                    } else {
                        collected.append(value);
                    }
                }
                lists[2] = MusicData::unique(lists[2], owned);
                lists[3] = MusicData::unique(lists[3], collected);
                for (const auto index : {2, 3}) {
                    totals[index] = int(lists[index].size());
                    hasMore[index] = page["more"].toBool();
                }
            }
            completePersonal(lane);
        },
        valid(token, &m_accountGeneration));
}

void MusicLibrary::loadTrackPage(int start) {
    if (current.isEmpty() || trackLoad || start + 3 < tracks.size() || trackCursor >= trackIDs.size()) {
        return;
    }
    trackLoad = true;
    const auto ids = MusicData::slice(trackIDs, trackCursor, 100);
    api.call(
        "songs", {QJsonValue(ids)},
        [this, ids](MusicReply result) {
            if (result.ok()) {
                trackCursor += ids.size();
                tracks = MusicData::unique(tracks, MusicData::ordered(ids, result.value.toArray()));
            } else {
                status = result.error;
            }
            trackLoad = false;
            changed();
        },
        valid(m_selectionGeneration, &m_selectionGeneration));
}

void MusicLibrary::sameAlbum() {
    const auto song = current;
    if (song["kind"] != "song" || detailLoading || song["albumID"].toString().isEmpty() || albumLoaded) {
        return;
    }
    albumLoaded = true;
    api.call(
        "detail",
        {MusicData::item("album", song["albumID"].toString(), song["album"].toString(),
                         song["artist"].toString(), provider)},
        [this](MusicReply result) {
            if (result.ok()) {
                const auto values = result.value.toArray();
                const auto album = values.at(0).toObject();
                current["description"] = album["description"];
                current["date"] = album["date"];
                tracks = values.at(1).toArray();
            } else {
                albumLoaded = false;
                status = result.error;
            }
            changed();
        },
        valid(m_selectionGeneration, &m_selectionGeneration));
}

void MusicLibrary::loadSongWiki() {
    wantsSongDetails = true;
    const auto value = current;
    if (value["kind"] != "song" || detailLoading || !value["wiki"].toString().isEmpty()) {
        return;
    }
    const auto token = m_selectionGeneration;
    const auto wikiToken = ++m_wikiGeneration;
    const auto selected = valid(token, &m_selectionGeneration);
    const auto wiki = valid(wikiToken, &m_wikiGeneration);
    api.call(
        "wiki", {value["id"]},
        [this, value](MusicReply result) {
            if (result.ok()) {
                current["wiki"] = result.value;
                details[value["key"].toString()] = current;
            } else {
                status = QStringLiteral("百科暂不可读取：") + result.error;
            }
            changed();
        },
        [selected, wiki] { return selected() && wiki(); });
}

void MusicLibrary::play() {
    if (current["kind"] != "song") {
        status = QStringLiteral("请先选择一首歌曲");
        changed();
        return;
    }
    player.play(current);
}

QJsonArray MusicLibrary::directoryQueue() const {
    if (!directory || directory->ids.isEmpty()) {
        return libraryItems();
    }
    QHash<QString, QJsonObject> loaded;
    for (const auto &value : directory->songs) {
        loaded[value.toObject()["id"].toString()] = value.toObject();
    }
    QJsonArray queue;
    for (const auto &id : directory->ids) {
        auto value = loaded.value(id.toString());
        if (value.isEmpty()) {
            value = MusicData::item("song", id.toString(), "待读取曲目", {}, provider);
            value["deferred"] = true;
        }
        queue.append(value);
    }
    return queue;
}

void MusicLibrary::playDirectory() {
    if (directory && !directory->songs.isEmpty()) {
        player.play(directory->songs.first().toObject(), directoryQueue());
    }
}

void MusicLibrary::playOfficial(QJsonObject value) {
    if (value.isEmpty()) {
        value = current;
    }
    if (value["kind"] != "song") {
        return;
    }
    if (value["provider"].toString(provider) != "netease") {
        host->open(sourceURL(value));
        return;
    }
    host->playOfficial(value["id"].toString(), [owner = QPointer(this)](QString message) {
        if (owner) {
            owner->status = message;
            owner->changed();
        }
    });
}

QString MusicLibrary::sourceURL(QJsonObject value) const {
    if (value.isEmpty()) {
        value = current;
    }
    if (value.isEmpty()) {
        return {};
    }
    const auto source = value["provider"].toString(provider);
    if (source == "netease") {
        return "https://music.163.com/#/" + value["kind"].toString() + "?id=" + value["id"].toString();
    }
    if (source == "kugou") {
        return QStringLiteral("https://www.kugou.com/");
    }
    const QHash<QString, QString> paths{{"song", "songDetail"},
                                        {"album", "albumDetail"},
                                        {"artist", "singer"},
                                        {"playlist", value["chart"].toBool() ? "toplist" : "playlist"}};
    return "https://y.qq.com/n/ryqq/" + paths.value(value["kind"].toString()) + "/" +
           QString::fromLatin1(QUrl::toPercentEncoding(value["id"].toString(), "!'()*"));
}
