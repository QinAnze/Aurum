#include "AudioPlayer.h"
#include <QUrl>
#include <algorithm>
#include <cmath>
#if defined(Q_OS_WIN) && QT_VERSION < QT_VERSION_CHECK(6, 9, 0)
#include <QtMultimedia/private/qaudiodevice_p.h>
#endif

/**
 * 建立播放器与默认输出设备监听；不持久化设备 ID。
 * 每次设备通知重新读取当前默认设备，避免蓝牙连接或切换后继续输出到启动时的设备。
 */
AudioPlayer::AudioPlayer(std::function<void()> changed) : playbackChanged(std::move(changed)) {
    normalizeOutputLayout(defaultOutput());
    output.setVolume(.7f);
    createPlayer();
    QObject::connect(
        &devices, &QMediaDevices::audioOutputsChanged, &devices, [this] { followDefaultOutput(); },
        Qt::QueuedConnection);
    followDefaultOutput();
}
/**
 * 修正 Qt 6.8 Windows 设备枚举中的无效声道位置，保留真正的 WASAPI 设备对象。
 * 必须在设备交给解码线程前执行；不改动系统设备配置，也不保存任何设备属性。
 */
void AudioPlayer::normalizeOutputLayout(const QAudioDevice &device) {
#if defined(Q_OS_WIN) && QT_VERSION < QT_VERSION_CHECK(6, 9, 0)
    if (device.isNull()) {
        return;
    }
    const auto configuration = quint32(device.channelConfiguration());
    constexpr quint32 knownPositions = (1u << QAudioFormat::NChannelPositions) - 2u;
    if (configuration != 0 && (configuration & ~knownPositions) == 0) {
        return;
    }
    const auto preferred = device.preferredFormat();
    auto replacement = preferred.channelConfig();
    if (replacement == QAudioFormat::ChannelConfigUnknown || (quint32(replacement) & ~knownPositions) != 0) {
        // 驱动的最大声道数不代表当前混音格式；只使用 GetMixFormat 返回的实际声道数。
        const auto channels = preferred.channelCount();
        if (channels < 1 || channels > 8) {
            return;
        }
        replacement = QAudioFormat::defaultChannelConfigForChannelCount(channels);
    }
    // Qt 6.8 的描述符字段可变。保留其具体 Windows 类型和 IMMDevice，不能替换成通用描述符。
    // 未知位置位会被 FFmpeg 转成空掩码；Qt 未检查转换失败，随后使用未初始化的布局。
    auto *descriptor = const_cast<QAudioDevicePrivate *>(device.handle());
    descriptor->channelConfiguration = replacement;
#else
    Q_UNUSED(device);
#endif
}
/**
 * 创建独立媒体会话并重新连接状态通知；重建时彻底释放旧后端和未完成的回调。
 * 输出对象保持不变，保留用户音量与当前默认设备。
 */
void AudioPlayer::createPlayer() {
    player.reset();
    player = std::make_unique<QMediaPlayer>();
    const auto changed = playbackChanged;
    if (changed) {
        // 播放状态事件立即唤醒；进度无需依附 60Hz 的场景循环。
        QObject::connect(player.get(), &QMediaPlayer::playbackStateChanged, player.get(),
                         [changed] { changed(); });
        QObject::connect(player.get(), &QMediaPlayer::mediaStatusChanged, player.get(),
                         [changed] { changed(); });
        QObject::connect(player.get(), &QMediaPlayer::errorOccurred, player.get(), [changed] { changed(); });
        QObject::connect(player.get(), &QMediaPlayer::durationChanged, player.get(),
                         [changed] { changed(); });
    }
    player->setAudioOutput(&output);
    QObject::connect(player.get(), &QMediaPlayer::positionChanged, player.get(), [this](qint64 position) {
        // 设备失效时原生后端可能先报 0；保留最后有效进度，主动换曲与跳转另行更新。
        if (!outputUnavailable && recoveryPosition < 0 && position > 0) {
            lastPosition = position;
        }
    });
    QObject::connect(
        player.get(), &QMediaPlayer::mediaStatusChanged, player.get(), [this] { restorePlaybackPosition(); },
        Qt::QueuedConnection);
    QObject::connect(
        player.get(), &QMediaPlayer::seekableChanged, player.get(), [this] { restorePlaybackPosition(); },
        Qt::QueuedConnection);
    QObject::connect(player.get(), &QMediaPlayer::mediaStatusChanged, player.get(), [this](auto status) {
        if (status == QMediaPlayer::EndOfMedia) {
            playbackRequested = false;
            ++ended;
        }
    });
    QObject::connect(player.get(), &QMediaPlayer::errorOccurred, player.get(), [this](auto, const QString &) {
        // 不回显底层错误中的临时签名链接；只向界面反馈可操作的错误。
        if (!outputUnavailable) {
            error = QStringLiteral("音频读取失败，请重试或打开来源页面");
        }
    });
}
/**
 * 等待新会话可跳转后恢复实际播放位置；FFmpeg 可能直接进入 BufferedMedia。
 * 恢复前的临时进度不能覆盖断开前的位置，也不能取消用户的暂停意图。
 */
void AudioPlayer::restorePlaybackPosition() {
    const auto status = player->mediaStatus();
    const bool ready = status == QMediaPlayer::LoadedMedia || status == QMediaPlayer::BufferedMedia;
    if (!ready || outputUnavailable || recoveryPosition < 0) {
        return;
    }
    // 不能跳转的实时流只能从当前起点恢复，不能因等待 seekable 而永久停住。
    const auto position = player->isSeekable() ? recoveryPosition : 0;
    recoveryPosition = -1;
    lastPosition = position;
    if (player->isSeekable()) {
        player->setPosition(position);
    }
    if (playbackRequested) {
        player->play();
    }
}
/**
 * 跟随系统默认设备，并在全部输出暂时消失时保留用户的播放意图。
 * 重连同一设备也重新绑定播放器；用户暂停或停止后不得因重连而自动播放。
 */
void AudioPlayer::followDefaultOutput() {
    const auto device = defaultOutput();
    if (device.isNull()) {
        if (!outputUnavailable) {
            recoveryPosition = std::max(lastPosition, player->position());
            outputUnavailable = true;
            player->pause();
            player->setAudioOutput(nullptr);
            error.clear();
        }
        return;
    }
    normalizeOutputLayout(device);
    if (!outputUnavailable && output.device() == device) {
        return;
    }
    const bool wasUnavailable = outputUnavailable;
    const auto source = pendingSource.isEmpty() ? player->source() : pendingSource;
    const auto position = std::max<qint64>(0, recoveryPosition);
    if (wasUnavailable) {
        // 全部设备消失后旧 Media Foundation 会话可能保留失效拓扑，必须彻底释放。
        player.reset();
    }
    output.setDevice(device);
    if (wasUnavailable) {
        createPlayer();
    } else {
        player->setAudioOutput(&output);
    }
    outputUnavailable = false;
    if (wasUnavailable && !source.isEmpty()) {
        pendingSource.clear();
        error.clear();
        recoveryPosition = position;
        player->setSource(source);
        // 先等新会话加载并恢复跳转，再开始播放，避免原生后端启动时覆盖待恢复的位置。
        return;
    }
    if (playbackRequested) {
        player->play();
    }
}
/**
 * 校验音源并交给系统解码播放，沿用原生状态和错误反馈。
 */
bool AudioPlayer::load(QString input, bool offline, bool alternative, QString provider) {
    QUrl url(input);
    const auto host = url.host();
    const bool qq = provider == "qq" && (host == "qqmusic.qq.com" || host.endsWith(".qqmusic.qq.com"));
    const bool kugou = provider == "kugou" && (host.endsWith(".kugou.com") || host.endsWith(".kugou.net"));
    const bool trusted =
        qq || kugou ||
        (provider == "netease" && (host == "music.126.net" || host.endsWith(".music.126.net") ||
                                   host == "music.163.com" || host.endsWith(".music.163.com")));
    const QStringList providers{"qq.com", "gtimg.com", "kuwo.cn", "kugou.com", "migu.cn"};
    const bool alternateHost =
        alternative && std::any_of(providers.begin(), providers.end(), [&](const auto &domain) {
            return host == domain || host.endsWith("." + domain);
        });
    if (offline ? !url.isLocalFile()
                : (!(trusted || alternateHost) || !QStringList{"http", "https"}.contains(url.scheme()))) {
        return false;
    }
    // 酷狗音源沿用上游返回的协议与签名地址
    if (url.scheme() == "http" && !kugou) {
        url.setScheme("https");
    }
    player->stop();
    playbackRequested = false;
    lastPosition = 0;
    recoveryPosition = -1;
    error.clear();
    pendingSource.clear();
    followDefaultOutput();
    if (outputUnavailable) {
        // 没有设备时延后创建解码拓扑，避免启动后再连接耳机被误报为音源错误。
        pendingSource = url;
        player->setSource({});
        playbackRequested = true;
        return true;
    }
    player->setSource(url);
    playbackRequested = true;
    followDefaultOutput();
    if (!outputUnavailable) {
        player->play();
    }
    return true;
}
void AudioPlayer::control(QString action, double value) {
    if (!std::isfinite(value)) {
        return;
    }
    if (action == "pause") {
        playbackRequested = false;
        player->pause();
    } else if (action == "resume") {
        playbackRequested = true;
        followDefaultOutput();
        if (!outputUnavailable) {
            player->play();
        }
    } else if (action == "stop") {
        playbackRequested = false;
        player->stop();
        player->setSource({});
        lastPosition = 0;
        recoveryPosition = -1;
        pendingSource.clear();
        error.clear();
    } else if (action == "seek" && player->isSeekable()) {
        lastPosition = qint64(std::clamp(value, 0., double(player->duration())));
        if (recoveryPosition >= 0) {
            recoveryPosition = lastPosition;
        }
        player->setPosition(lastPosition);
    } else if (action == "volume") {
        output.setVolume(float(std::clamp(value, 0., 1.)));
    }
}
QVariantMap AudioPlayer::state() const {
    const auto position = recoveryPosition >= 0 ? recoveryPosition : player->position();
    return {{"playing", player->isPlaying()},
            {"position", position},
            {"duration", player->duration()},
            {"seekable", player->isSeekable()},
            {"volume", output.volume()},
            {"ended", ended},
            {"error", error},
            {"buffering", player->mediaStatus() == QMediaPlayer::LoadingMedia ||
                              player->mediaStatus() == QMediaPlayer::StalledMedia}};
}
