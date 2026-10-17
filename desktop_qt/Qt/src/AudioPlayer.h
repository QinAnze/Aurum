#pragma once
#include <QAudioDevice>
#include <QAudioOutput>
#include <QMediaPlayer>
#include <QMediaDevices>
#include <QUrl>
#include <QVariantMap>
#include <functional>
#include <memory>

// 原生音频只接收已由锁定上游取得的播放链接；不保存链接或账号信息。
class AudioPlayer {
  public:
    explicit AudioPlayer(std::function<void()> changed = {});
    bool load(QString input, bool offline, bool alternative = false, QString provider = "netease");
    void control(QString action, double value = 0);
    QVariantMap state() const;

  private:
    friend class AudioPlayerRegression;
    QMediaDevices devices;
    QAudioOutput output;
    std::unique_ptr<QMediaPlayer> player;
    std::function<void()> playbackChanged;
    std::function<QAudioDevice()> defaultOutput = QMediaDevices::defaultAudioOutput;
    bool playbackRequested = false;
    bool outputUnavailable = false;
    qint64 lastPosition = 0;
    qint64 recoveryPosition = -1;
    QUrl pendingSource;
    int ended = 0;
    QString error;
    static void normalizeOutputLayout(const QAudioDevice &device);
    void restorePlaybackPosition();
    void createPlayer();
    void followDefaultOutput();
};
