#include "LyricsController.h"
#include <QJsonDocument>
#include <QPointer>
#include <QRegularExpression>
#include <algorithm>
#include <cmath>

namespace {
const QStringList PROVIDERS{"netease", "qq", "kugou"};
constexpr int CACHE_LIMIT = 12;

QString comparable(QString value) {
    static const QRegularExpression remove(QStringLiteral("[\\s\\p{P}\\p{S}]"),
                                           QRegularExpression::UseUnicodePropertiesOption);
    return value.normalized(QString::NormalizationForm_KC).toLower().remove(remove);
}

QStringList artists(const QJsonObject &track) {
    QStringList values;
    for (const auto &artist : track["artists"].toArray()) {
        values.append(artist.toObject()["name"].toString());
    }
    if (values.isEmpty()) {
        values = track["artist"].toString().split(QRegularExpression(QStringLiteral("\\s*/\\s*")));
    }
    QStringList normalized;
    for (const auto &value : values) {
        const auto text = comparable(value);
        if (!text.isEmpty()) {
            normalized.append(text);
        }
    }
    normalized.sort();
    return normalized;
}

QString recordingVersion(const QJsonObject &track) {
    const auto text = (track["title"].toString() + " " + track["album"].toString()).toLower();
    QStringList versions;
    for (const auto &version :
         {"live", "remix", "demo", "acoustic", "instrumental", "伴奏", "翻唱", "现场", "重录"}) {
        if (text.contains(QString::fromUtf8(version))) {
            versions.append(QString::fromUtf8(version));
        }
    }
    versions.sort();
    return versions.join('/');
}
}

LyricsController::LyricsController(Host *host, QObject *parent) : QObject(parent), m_host(host) {
    for (qsizetype i = 0; i < PROVIDERS.size(); ++i) {
        m_apis[i] = std::make_unique<MusicApi>(host);
        m_apis[i]->provider = PROVIDERS[i];
    }
    const auto cached = QJsonDocument::fromJson(host->preference("lyrics-cache").toUtf8()).array();
    for (const auto &value : cached) {
        const auto entry = value.toObject();
        if (entry["key"].isString() && validDocument(entry["document"].toObject())) {
            m_cache.append(QJsonObject{{"key", entry["key"]}, {"document", entry["document"]}});
            if (m_cache.size() == CACHE_LIMIT) {
                break;
            }
        }
    }
}

QString LyricsController::trackKey(const QJsonObject &track) {
    if (track.isEmpty()) {
        return {};
    }
    return track["provider"].toString("netease") + ":" + track["id"].toString();
}

bool LyricsController::validDocument(const QJsonObject &document) {
    if (document["version"].toInt() != 1 ||
        !QStringList{"line", "word", "none"}.contains(document["timing"].toString()) ||
        !document["lines"].isArray() || document["lines"].toArray().size() > 5000 ||
        !document["plainText"].isString() || !document["offsetMs"].isDouble() ||
        !std::isfinite(document["offsetMs"].toDouble())) {
        return false;
    }
    for (const auto &value : document["lines"].toArray()) {
        const auto line = value.toObject();
        if (!line["startMs"].isDouble() || !std::isfinite(line["startMs"].toDouble()) ||
            !line["text"].isString()) {
            return false;
        }
    }
    return true;
}

bool LyricsController::sameRecording(const QJsonObject &track, const QJsonObject &candidate) {
    const auto sourceArtists = artists(track);
    return comparable(track["title"].toString()) == comparable(candidate["title"].toString()) &&
           !sourceArtists.isEmpty() && sourceArtists == artists(candidate) &&
           recordingVersion(track) == recordingVersion(candidate) && track["duration"].toDouble() > 0 &&
           candidate["duration"].toDouble() > 0 &&
           std::abs(track["duration"].toDouble() - candidate["duration"].toDouble()) <= 2000;
}

int LyricsController::activeLineIndex(const QJsonObject &document, double positionMs, double offsetMs) {
    const auto lines = document["lines"].toArray();
    const auto position = positionMs + document["offsetMs"].toDouble() + offsetMs;
    qsizetype lower = 0;
    qsizetype upper = lines.size();
    while (lower < upper) {
        const auto middle = (lower + upper) / 2;
        if (lines.at(middle).toObject()["startMs"].toDouble() <= position) {
            lower = middle + 1;
        } else {
            upper = middle;
        }
    }
    return int(lower) - 1;
}

void LyricsController::clear() {
    ++m_generation;
    currentKey.clear();
    m_document = {};
    m_starts.clear();
    status = "idle";
    message.clear();
    index = -1;
    offsetMs = 0;
    positionMs = 0;
}

MusicApi &LyricsController::api(const QString &provider) {
    const auto index = PROVIDERS.indexOf(provider);
    return *m_apis[index < 0 ? 0 : index];
}

MusicApi::Valid LyricsController::valid(const Pending &pending) {
    return [owner = QPointer(this), generation = pending->generation] {
        return owner && owner->m_generation == generation;
    };
}

/** 切歌先清空显示，再读精确 ID；缺词时只接受同名、同歌手、同版本的录音补缺。 */
void LyricsController::load(const QJsonObject &track, bool retry) {
    const auto key = trackKey(track);
    const auto position = key == currentKey ? positionMs : 0;
    clear();
    currentKey = key;
    positionMs = position;
    if (!retry) {
        for (const auto &entry : m_cache) {
            if (entry.toObject()["key"].toString() == currentKey) {
                accept(entry.toObject()["document"].toObject(), track);
                return;
            }
        }
    }
    status = "loading";
    message = QStringLiteral("正在读取歌词…");
    emit changed();
    auto pending = std::make_shared<Load>();
    pending->generation = m_generation;
    pending->track = track;
    api(track["provider"].toString("netease"))
        .call(
            "lyrics", {track},
            [this, pending](MusicReply result) {
                pending->networkFailed = !result.ok();
                const auto document = result.value.toObject();
                if (result.ok() && validDocument(document)) {
                    pending->native = document;
                    if (!document["lines"].toArray().isEmpty()) {
                        accept(document, pending->track);
                        return;
                    }
                }
                supplement(pending);
            },
            valid(pending));
}

void LyricsController::supplement(const Pending &pending) {
    const auto source = pending->track["provider"].toString("netease");
    while (pending->provider < PROVIDERS.size() && PROVIDERS[pending->provider] == source) {
        ++pending->provider;
    }
    if (pending->provider >= PROVIDERS.size()) {
        finish(pending);
        return;
    }
    pending->queries = {pending->track["title"].toString() + " " + pending->track["artist"].toString(),
                        pending->track["title"].toString()};
    pending->queries.removeDuplicates();
    pending->query = 0;
    search(pending);
}

void LyricsController::search(const Pending &pending) {
    if (pending->query >= pending->queries.size()) {
        ++pending->provider;
        supplement(pending);
        return;
    }
    api(PROVIDERS[pending->provider])
        .call(
            "search", {pending->queries[pending->query], "song", 0},
            [this, pending](MusicReply result) {
                if (!result.ok()) {
                    pending->networkFailed = true;
                    ++pending->provider;
                    supplement(pending);
                    return;
                }
                pending->candidates = {};
                for (const auto &candidate : result.value.toObject()["items"].toArray()) {
                    if (sameRecording(pending->track, candidate.toObject())) {
                        pending->candidates.append(candidate);
                        if (pending->candidates.size() == 2) {
                            break;
                        }
                    }
                }
                pending->candidate = 0;
                fetchCandidate(pending);
            },
            valid(pending));
}

void LyricsController::fetchCandidate(const Pending &pending) {
    if (pending->candidate >= pending->candidates.size()) {
        ++pending->query;
        search(pending);
        return;
    }
    const auto candidate = pending->candidates.at(pending->candidate).toObject();
    api(PROVIDERS[pending->provider])
        .call(
            "lyrics", {candidate},
            [this, pending, candidate](MusicReply result) {
                if (!result.ok()) {
                    pending->networkFailed = true;
                    ++pending->provider;
                    supplement(pending);
                    return;
                }
                auto document = result.value.toObject();
                if (validDocument(document) && !document["lines"].toArray().isEmpty()) {
                    document["sourceTrackId"] = candidate["id"];
                    accept(document, pending->track);
                    return;
                }
                ++pending->candidate;
                fetchCandidate(pending);
            },
            valid(pending));
}

void LyricsController::finish(const Pending &pending) {
    if (!pending->native["plainText"].toString().isEmpty()) {
        accept(pending->native, pending->track);
        return;
    }
    status = pending->networkFailed ? "error" : "empty";
    message = pending->networkFailed ? QStringLiteral("歌词暂不可用，点击重试")
                                     : QStringLiteral("暂无歌词 / 纯音乐");
    emit changed();
}

void LyricsController::accept(QJsonObject document, const QJsonObject &track) {
    document["trackKey"] = trackKey(track);
    m_document = document;
    m_starts.clear();
    for (const auto &line : document["lines"].toArray()) {
        m_starts.append(line.toObject()["startMs"].toDouble());
    }
    status = m_starts.isEmpty() ? "plain" : "ready";
    message = m_starts.isEmpty() ? QStringLiteral("此歌词没有时间信息") : QString();
    index = activeLineIndex(document, positionMs, offsetMs);
    QJsonArray cache{QJsonObject{{"key", currentKey}, {"document", document}}};
    for (const auto &entry : m_cache) {
        if (entry.toObject()["key"].toString() != currentKey && cache.size() < CACHE_LIMIT) {
            cache.append(entry);
        }
    }
    m_cache = cache;
    persist();
    emit changed();
}

void LyricsController::persist() {
    auto serialized = QString::fromUtf8(QJsonDocument(m_cache).toJson(QJsonDocument::Compact));
    while (serialized.size() >= 240000 && !m_cache.isEmpty()) {
        m_cache.removeLast();
        serialized = QString::fromUtf8(QJsonDocument(m_cache).toJson(QJsonDocument::Compact));
    }
    m_host->setPreference("lyrics-cache", serialized);
}

void LyricsController::sync(double position) {
    positionMs = position;
    const auto time = position + m_document["offsetMs"].toDouble() + offsetMs;
    const auto next = int(std::upper_bound(m_starts.begin(), m_starts.end(), time) - m_starts.begin()) - 1;
    if (next != index) {
        index = next;
        emit changed();
    }
}

void LyricsController::adjustOffset(double deltaMs) {
    offsetMs = std::clamp(offsetMs + deltaMs, -10000., 10000.);
    sync(positionMs);
    emit changed();
}
