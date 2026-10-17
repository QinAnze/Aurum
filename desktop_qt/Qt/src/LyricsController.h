#pragma once
#include "MusicApi.h"
#include <array>
#include <memory>

class LyricsController : public QObject {
    Q_OBJECT
  public:
    explicit LyricsController(Host *host, QObject *parent = nullptr);
    void clear();
    void load(const QJsonObject &track, bool retry = false);
    void sync(double positionMs);
    void adjustOffset(double deltaMs);
    const QJsonObject &document() const {
        return m_document;
    }
    QString status = "idle";
    QString message;
    QString currentKey;
    int index = -1;
    double offsetMs = 0;
    double positionMs = 0;
    static bool validDocument(const QJsonObject &document);
    static bool sameRecording(const QJsonObject &track, const QJsonObject &candidate);
    static QString trackKey(const QJsonObject &track);
    static int activeLineIndex(const QJsonObject &document, double positionMs, double offsetMs = 0);

  signals:
    void changed();

  private:
    struct Load {
        quint64 generation = 0;
        QJsonObject track;
        QJsonObject native;
        bool networkFailed = false;
        int provider = 0;
        QStringList queries;
        int query = 0;
        QJsonArray candidates;
        int candidate = 0;
    };
    using Pending = std::shared_ptr<Load>;
    Host *m_host;
    std::array<std::unique_ptr<MusicApi>, 3> m_apis;
    quint64 m_generation = 0;
    QJsonObject m_document;
    QVector<double> m_starts;
    QJsonArray m_cache;
    MusicApi &api(const QString &provider);
    MusicApi::Valid valid(const Pending &pending);
    void supplement(const Pending &pending);
    void search(const Pending &pending);
    void fetchCandidate(const Pending &pending);
    void finish(const Pending &pending);
    void accept(QJsonObject document, const QJsonObject &track);
    void persist();
};
