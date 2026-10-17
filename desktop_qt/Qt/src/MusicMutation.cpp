#include "MusicLibrary.h"
#include "MusicData.h"
#include <algorithm>

namespace {
QJsonArray without(const QJsonArray &values, const QString &field, const QJsonValue &key) {
    QJsonArray result;
    for (const auto &value : values) {
        const auto match = field.isEmpty() ? value : value.toObject()[field];
        if (match != key) {
            result.append(value);
        }
    }
    return result;
}
}

/** 写操作串行化并核对账号代数；成功后才更新本地集合和失效元数据缓存。 */
void MusicLibrary::mutate(QString route, QJsonObject values, std::function<void(QJsonObject)> success,
                          Completion done) {
    if (!editable() || writeLoading || uid.isEmpty()) {
        if (!editable()) {
            status = providerName() + QStringLiteral("当前支持读取与播放");
        } else if (uid.isEmpty()) {
            status = QStringLiteral("请先登录网易云");
        }
        changed();
        if (done) {
            done(false);
        }
        return;
    }
    writeLoading = true;
    changed();
    api.request(
        route, values,
        [this, success, done](MusicReply result) {
            bool ok = result.ok();
            const auto body = result.value.toObject();
            const auto nestedCode = body["body"].toObject()["code"].toInt(200);
            if (ok && nestedCode != 200) {
                ok = false;
                status = QStringLiteral("网易云返回 ") + QString::number(nestedCode);
            } else if (ok) {
                host->invalidateMetadata();
                if (success) {
                    success(body);
                }
                status = QStringLiteral("已同步至网易云");
            } else {
                status = result.error;
            }
            writeLoading = false;
            changed();
            if (done) {
                done(ok);
            }
        },
        valid(m_accountGeneration, &m_accountGeneration));
}

void MusicLibrary::like(QJsonObject value) {
    if (value.isEmpty()) {
        value = current;
    }
    if (value["kind"] != "song") {
        return;
    }
    if (uid.isEmpty()) {
        status = QStringLiteral("请先登录网易云");
        changed();
        return;
    }
    if (!likedIDs) {
        api.call(
            "likedIDs", {uid},
            [this, value](MusicReply result) {
                if (result.ok()) {
                    likedIDs = result.value.toArray();
                    like(value);
                } else {
                    status = result.error;
                    changed();
                }
            },
            valid(m_accountGeneration, &m_accountGeneration));
        return;
    }
    const auto liked = MusicData::indexOf(*likedIDs, value["id"]) >= 0 ||
                       MusicData::indexOfId(lists[1], value["id"].toString()) >= 0;
    mutate("/like", {{"id", value["id"]}, {"like", !liked}}, [this, value, liked](QJsonObject) {
        if (liked) {
            lists[1] = without(lists[1], "id", value["id"]);
            if (likedIDs) {
                *likedIDs = without(*likedIDs, {}, value["id"]);
            }
        } else {
            lists[1] = MusicData::unique(lists[1], {value});
            if (likedIDs) {
                likedIDs->append(value["id"]);
            }
        }
        totals[1] = int(likedIDs ? likedIDs->size() : lists[1].size());
    });
}

void MusicLibrary::subscribe(QJsonObject value) {
    if (value.isEmpty()) {
        value = current;
    }
    const auto kind = value["kind"].toString();
    if (!QStringList{"album", "playlist", "artist"}.contains(kind)) {
        return;
    }
    const auto lane = kind == "album" ? 4 : 3;
    const auto key = value["key"].toString();
    bool subscribed = subscriptions.contains(key);
    for (const auto &entry : lists[lane]) {
        subscribed |= entry.toObject()["key"] == key;
    }
    mutate(kind == "playlist" ? "/playlist/subscribe" : "/" + kind + "/sub",
           {{"id", value["id"]}, {"t", subscribed ? 2 : 1}},
           [this, value, kind, lane, key, subscribed](QJsonObject) {
               if (subscribed) {
                   subscriptions.remove(key);
                   if (kind != "artist") {
                       lists[lane] = without(lists[lane], "key", key);
                   }
               } else {
                   subscriptions.insert(key);
                   if (kind != "artist") {
                       lists[lane] = MusicData::unique(lists[lane], {value});
                   }
               }
               if (kind != "artist") {
                   totals[lane] = int(lists[lane].size());
               }
           });
}

void MusicLibrary::playlistForm(QString kind, QString name, QString id, Completion done) {
    name = name.trimmed();
    if (name.isEmpty() || name.toUcs4().size() > 100) {
        status = QStringLiteral("请输入 1–100 字歌单名称");
        changed();
        if (done) {
            done(false);
        }
        return;
    }
    if (kind == "rename" && MusicData::indexOfId(lists[2], id) < 0 &&
        !(directory && directory->item["id"] == id && directory->item["creatorID"] == uid)) {
        status = QStringLiteral("只能编辑自己创建的歌单");
        changed();
        if (done) {
            done(false);
        }
        return;
    }
    mutate(
        kind == "create" ? "/playlist/create" : "/playlist/name/update",
        kind == "create" ? QJsonObject{{"name", name}} : QJsonObject{{"id", id}, {"name", name}},
        [this, kind, name, id](QJsonObject body) {
            if (kind == "create" && body["playlist"].isObject()) {
                const auto value = MusicData::parse(body["playlist"].toObject(), "playlist");
                if (!value.isEmpty()) {
                    lists[2] = MusicData::unique(lists[2], {value});
                }
            }
            if (kind == "rename") {
                for (qsizetype i = 0; i < lists[2].size(); ++i) {
                    auto value = lists[2].at(i).toObject();
                    if (value["id"] == id) {
                        value["title"] = name;
                        lists[2].replace(i, value);
                    }
                }
                if (directory && directory->item["id"] == id) {
                    directory->item["title"] = name;
                }
            }
            totals[2] = int(lists[2].size());
        },
        done);
}

void MusicLibrary::playlistTrack(QString id, QJsonObject value, bool remove, Completion done) {
    if (value.isEmpty()) {
        value = current;
    }
    if (value["kind"] != "song") {
        if (done) {
            done(false);
        }
        return;
    }
    if (MusicData::indexOfId(lists[2], id) < 0 &&
        !(directory && directory->item["id"] == id && directory->item["creatorID"] == uid)) {
        status = QStringLiteral("请选择自己创建的歌单");
        changed();
        if (done) {
            done(false);
        }
        return;
    }
    mutate(
        "/playlist/tracks", {{"pid", id}, {"tracks", value["id"]}, {"op", remove ? "del" : "add"}},
        [this, id, value, remove](QJsonObject) {
            if (!directory || directory->item["id"] != id) {
                return;
            }
            directory->songs = remove ? without(directory->songs, "id", value["id"])
                                      : MusicData::unique(directory->songs, {value});
            if (remove) {
                const auto old = MusicData::indexOf(directory->ids, value["id"]);
                if (old >= 0 && old < directory->cursor) {
                    directory->cursor = std::max(0, directory->cursor - 1);
                }
                directory->ids = without(directory->ids, {}, value["id"]);
                directory->item["trackCount"] = std::max(0, directory->item["trackCount"].toInt() - 1);
                directory->index = std::min(directory->index, std::max(0, int(directory->songs.size()) - 1));
            }
        },
        done);
}
