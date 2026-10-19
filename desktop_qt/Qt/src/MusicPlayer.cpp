#include "MusicPlayer.h"
#include <QJsonDocument>
#include <QPointer>
#include <QRandomGenerator>
#include <QRegularExpression>
#include <algorithm>

QString MusicPlayer::identity(const QJsonObject &track) {
    return track["provider"].toString("netease") + ":" + track["id"].toString();
}

MusicPlayer::MusicPlayer(Host *host, MusicApi *api, QObject *parent)
    : QObject(parent), lyrics(host), m_host(host), m_api(api) {
    state = {{"playing", false}, {"position", 0}, {"duration", 0}, {"volume", 0.7}, {"seekable", false}};
    quality = host->preference("quality");
    if (!QStringList{"standard", "higher", "exhigh", "lossless", "hires", "jymaster"}.contains(quality)) {
        quality = "exhigh";
    }
    alternative = host->preference("alternate-source") == "on";
    const auto saved = QJsonDocument::fromJson(host->preference("play-history").toUtf8()).array();
    const QRegularExpression identifier(QStringLiteral("^[a-zA-Z0-9_-]{1,80}$"));
    for (const auto &value : saved) {
        const auto track = value.toObject();
        if (track["kind"] == "song" && identifier.match(track["id"].toString()).hasMatch()) {
            history.append(track);
            if (history.size() == 200) {
                break;
            }
        }
    }
    connect(&lyrics, &LyricsController::changed, this, &MusicPlayer::changed);
}

MusicApi::Valid MusicPlayer::valid(quint64 generation) {
    return [owner = QPointer(this), generation] { return owner && owner->m_generation == generation; };
}

void MusicPlayer::enqueue(const QJsonObject &track, bool next) {
    if (track["kind"] != "song") {
        return;
    }
    for (qsizetype i = 0; i < queue.size(); ++i) {
        if (i != index && identity(queue.at(i).toObject()) == identity(track)) {
            queue.removeAt(i);
            if (i < index) {
                --index;
            }
            break;
        }
    }
    queue.insert(next ? std::max(0, index + 1) : queue.size(), track);
    emit changed();
}

/** 停止旧音源并推进代数，先完成元数据再交付播放；迟到的地址不能恢复旧曲目。 */
void MusicPlayer::play(QJsonObject track, std::optional<QJsonArray> source, std::optional<int> queueIndex) {
    if (track["kind"] != "song") {
        return;
    }
    if (source) {
        QSet<QString> seen;
        queue = {};
        for (const auto &value : *source) {
            const auto song = value.toObject();
            const auto key = identity(song);
            if (song["kind"] == "song" && !seen.contains(key)) {
                seen.insert(key);
                queue.append(song);
            }
        }
    }
    int selected = -1;
    for (qsizetype i = 0; i < queue.size(); ++i) {
        if (identity(queue.at(i).toObject()) == identity(track)) {
            selected = int(i);
            break;
        }
    }
    if (selected < 0) {
        selected = int(queue.size());
        queue.append(track);
    }
    index = queueIndex.value_or(selected);
    const auto generation = ++m_generation;
    m_host->mediaControl("stop");
    current = track;
    lyrics.clear();
    coverImage.clear();
    loading = true;
    failed = false;
    trial = false;
    status = QStringLiteral("正在准备：") + track["title"].toString();
    emit changed();
    if (!track["deferred"].toBool()) {
        prepare(track, generation);
        return;
    }
    m_api->call(
        "songs", {QJsonValue(QJsonArray{track["id"]})},
        [this, generation](MusicReply result) {
            const auto songs = result.value.toArray();
            if (!result.ok() || songs.isEmpty()) {
                fail(result.ok() ? QStringLiteral("此曲目暂不可读取") : result.error);
                return;
            }
            current = songs.first().toObject();
            if (index >= 0 && index < queue.size()) {
                queue.replace(index, current);
            }
            emit changed();
            prepare(current, generation);
        },
        valid(generation));
}

void MusicPlayer::prepare(QJsonObject track, quint64 generation) {
    if (!track["cover"].toString().isEmpty()) {
        m_host->loadCover(track["cover"].toString(), [this, alive = valid(generation)](QString key) {
            if (alive()) {
                coverImage = key;
                emit changed();
            }
        });
    }
    emit trackSelected(track);
    lyrics.load(track);
    m_api->call(
        "playback", {track, quality, alternative},
        [this, track](MusicReply result) {
            if (!result.ok()) {
                fail(result.error);
                return;
            }
            const auto audio = result.value.toObject();
            const auto url = audio["url"].toString();
            if (url.isEmpty()) {
                fail(QStringLiteral("此歌曲暂无可用音源，请检查登录和歌曲权限"));
                return;
            }
            m_host->mediaMetadata(track["title"].toString(), track["artist"].toString(),
                                  track["album"].toString());
            if (!m_host->mediaLoad(url, m_api->provider == "netease" && alternative)) {
                fail(QStringLiteral("音频地址不可用"));
                return;
            }
            m_endSerial = m_host->mediaState().value("ended").toLongLong();
            auto entry = track;
            entry["wiki"] = "";
            entry["description"] = "";
            QJsonArray recent{entry};
            for (const auto &value : history) {
                if (identity(value.toObject()) != identity(track) && recent.size() < 200) {
                    recent.append(value);
                }
            }
            history = recent;
            m_host->setPreference("play-history",
                                  QString::fromUtf8(QJsonDocument(history).toJson(QJsonDocument::Compact)));
            const auto preview = audio["freeTrialInfo"];
            trial = preview.isObject() || preview.isArray() ||
                    (preview.isString() && !preview.toString().isEmpty() && preview.toString() != "null") ||
                    (preview.isBool() && preview.toBool()) || (preview.isDouble() && preview.toDouble() != 0);
            status = trial ? QStringLiteral("当前音源为试听片段")
                           : QStringLiteral("正在播放：") + track["title"].toString();
            if (!audio["qualityFallback"].toString().isEmpty()) {
                status += QStringLiteral("（已切换为") + audio["qualityFallback"].toString() +
                          QStringLiteral("音质）");
            }
            loading = false;
            emit changed();
        },
        valid(generation));
}

void MusicPlayer::fail(QString error) {
    failed = true;
    status = error;
    loading = false;
    emit changed();
}

void MusicPlayer::tick(double time, bool force) {
    if (!force && time - m_lastPoll < 0.1) {
        return;
    }
    m_lastPoll = time;
    const auto previous = state;
    const auto update = QJsonObject::fromVariantMap(m_host->mediaState());
    for (auto it = update.begin(); it != update.end(); ++it) {
        state[it.key()] = it.value();
    }
    lyrics.sync(state["position"].toDouble());
    if (state != previous) {
        emit changed();
    }
    if (!state["error"].toString().isEmpty()) {
        failed = true;
        status = state["error"].toString();
    }
    if (!current.isEmpty() && !loading && state.contains("ended") &&
        state["ended"].toInteger() != m_endSerial) {
        m_endSerial = state["ended"].toInteger();
        if (onEnd) {
            onEnd();
        } else {
            next(1, true);
        }
    }
}

void MusicPlayer::toggle() {
    if (!loading && !current.isEmpty()) {
        m_host->mediaControl(state["playing"].toBool() ? "pause" : "resume");
    }
}

void MusicPlayer::seek(double fraction) {
    if (state["seekable"].toBool()) {
        m_host->mediaControl("seek", std::clamp(fraction, 0., 1.) * state["duration"].toDouble());
    }
}

void MusicPlayer::volume(double value) {
    const auto volume = std::clamp(value, 0., 1.);
    m_host->mediaControl("volume", volume);
    m_host->setPreference("volume", QString::number(volume));
}

void MusicPlayer::next(int direction, bool ended) {
    if (queue.isEmpty()) {
        return;
    }
    if (ended && mode == "one") {
        play(current, std::nullopt, index);
        return;
    }
    auto selected = index + direction;
    if (mode == "shuffle" && queue.size() > 1) {
        selected = (index + 1 + QRandomGenerator::global()->bounded(int(queue.size() - 1))) % queue.size();
    }
    if (selected >= queue.size() && mode == "off") {
        status = QStringLiteral("队列已播放完");
        emit changed();
        return;
    }
    selected = ((selected % queue.size()) + queue.size()) % queue.size();
    play(queue.at(selected).toObject(), std::nullopt, selected);
}

void MusicPlayer::remove(int selected) {
    if (selected < 0 || selected >= queue.size() || selected == index) {
        return;
    }
    queue.removeAt(selected);
    if (selected < index) {
        --index;
    }
    emit changed();
}

void MusicPlayer::clearUpcoming() {
    queue = current.isEmpty() ? QJsonArray{} : QJsonArray{current};
    index = current.isEmpty() ? -1 : 0;
    emit changed();
}

/** 停止播放并作废音源与歌词请求；保留音量和历史等可恢复偏好。 */
void MusicPlayer::stop() {
    ++m_generation;
    lyrics.clear();
    loading = false;
    failed = false;
    status.clear();
    coverImage.clear();
    current = {};
    queue = {};
    index = -1;
    m_host->mediaControl("stop");
    m_host->mediaMetadata({}, {}, {});
    state["playing"] = false;
    state["position"] = 0;
    state["duration"] = 0;
    emit changed();
}
