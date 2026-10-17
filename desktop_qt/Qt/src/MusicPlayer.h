#pragma once
#include "LyricsController.h"
#include <optional>

class MusicPlayer : public QObject {
    Q_OBJECT
  public:
    MusicPlayer(Host *host, MusicApi *api, QObject *parent = nullptr);
    void enqueue(const QJsonObject &track, bool next = false);
    void play(QJsonObject track, std::optional<QJsonArray> source = std::nullopt,
              std::optional<int> queueIndex = std::nullopt);
    void tick(double time, bool force = false);
    void toggle();
    void seek(double fraction);
    void volume(double value);
    void next(int direction = 1, bool ended = false);
    void remove(int index);
    void clearUpcoming();
    void stop();
    static QString identity(const QJsonObject &track);
    LyricsController lyrics;
    QJsonArray queue;
    QJsonArray history;
    QJsonObject current;
    QJsonObject state;
    int index = -1;
    bool loading = false;
    bool failed = false;
    bool trial = false;
    QString coverImage;
    QString mode = "all";
    QString status;
    QString quality;
    bool alternative = false;
    std::function<void()> onEnd;

  signals:
    void changed();
    void trackSelected(QJsonObject track);

  private:
    Host *m_host;
    MusicApi *m_api;
    quint64 m_generation = 0;
    qint64 m_endSerial = 0;
    double m_lastPoll = -1;
    MusicApi::Valid valid(quint64 generation);
    void prepare(QJsonObject track, quint64 generation);
    void fail(QString error);
};
