#include "Engine.h"
#include "MusicData.h"
#include "MusicDiscover.h"
#include "RhiScene.h"
#include <QCoreApplication>
#include <QDataStream>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QJsonDocument>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QPainter>
#include <QQuickItem>
#include <QQuickWindow>
#include <QTemporaryDir>
#include <QThread>
#include <QUrl>
#include <QWheelEvent>
#include <functional>
#include <algorithm>
#include <cmath>

namespace {
/**
 * GPU 资源重建后只允许极少像素出现一个 RGB8 量化单位的舍入差异。
 * 尺寸、透明度及明显颜色差异仍严格失败；帧数据、HUD 命令和矩阵另行逐字节验证。
 */
bool equivalentGpuPixels(const QImage &expected, const QImage &actual, int &changedPixels,
                         qint64 pixelsPerDifference = 100000) {
    changedPixels = 0;
    if (expected.isNull() || expected.size() != actual.size()) {
        return false;
    }
    if (expected == actual) {
        return true;
    }
    const auto first = expected.convertToFormat(QImage::Format_RGBA8888);
    const auto second = actual.convertToFormat(QImage::Format_RGBA8888);
    const auto limit = qMax<qint64>(1, qint64(first.width()) * first.height() / pixelsPerDifference);
    for (int y = 0; y < first.height(); ++y) {
        const auto before = first.constScanLine(y);
        const auto after = second.constScanLine(y);
        for (int x = 0; x < first.width(); ++x) {
            bool changed = false;
            for (int channel = 0; channel < 4; ++channel) {
                const int difference = std::abs(int(before[x * 4 + channel]) - int(after[x * 4 + channel]));
                if (difference > 1 || (channel == 3 && difference != 0)) {
                    return false;
                }
                changed |= difference != 0;
            }
            if (changed && ++changedPixels > limit) {
                return false;
            }
        }
    }
    return true;
}
}

/** 离线 GPU 基准复用逐通道 RGB8 检查，并限制独立设备之间的舍入像素数量。 */
bool runGpuReferenceCheck(const QImage &expected, const QImage &actual) {
    int changedPixels = 0;
    // 两个独立 QRhi 设备允许最多万分之一像素出现一个 RGB8 单位的舍入，透明度仍须精确相同。
    // 窗口资源重建继续使用默认的十万分之一预算；场景数据和矩阵另外严格对照。
    const auto same = equivalentGpuPixels(expected, actual, changedPixels, 10000);
    if (changedPixels > 0) {
        qInfo() << "GPU reference RGB8 rounding pixels:" << changedPixels;
    }
    const auto output = qEnvironmentVariable("RHINE_GPU_DIFF");
    if (!same && !output.isEmpty()) {
        QDir().mkpath(output);
        expected.save(output + "/expected.png");
        actual.save(output + "/actual.png");
    }
    return same;
}

/** 用真实 QML 输入和 QRhi 窗口验证原生业务，全部数据来自本地夹具。 */
int runUiChecks(Engine &backend, QQuickWindow *window, const QString &output) {
    if (!window || !backend.ready() || !backend.scene.review("archive")) {
        return 1;
    }
    auto &music = backend.app->music;
    auto &hud = backend.app->hud;
    auto &player = music.player;
    bool ok = true;
    const auto check = [&](bool value, const char *name) {
        if (!value) {
            qCritical() << "UI regression:" << name;
        }
        ok &= value;
    };
    const auto settle = [] {
        QElapsedTimer wait;
        wait.start();
        while (wait.elapsed() < 150) {
            QCoreApplication::processEvents();
            QThread::msleep(1);
        }
    };
    QElapsedTimer wait;
    QJsonArray songs;
    for (int index = 1; index <= 40; ++index) {
        auto song = MusicData::item("song", QString::number(index), "本地测试曲目 " + QString::number(index),
                                    "测试歌手");
        song["album"] = "测试专辑";
        song["albumID"] = "7";
        song["duration"] = 180000;
        song["wiki"] = "本地验证";
        songs.append(song);
        music.details.insert(song["key"].toString(), song);
    }
    QJsonArray lyricLines;
    const QStringList lyricTexts{"风穿过安静的街道", "我们听见远处的回声", "每一束光都落在这里",
                                 "让这首歌继续流动"};
    for (int index = 0; index < lyricTexts.size(); ++index) {
        lyricLines.append(QJsonObject{{"startMs", index * 1000},
                                      {"endMs", QJsonValue::Null},
                                      {"text", lyricTexts.at(index)},
                                      {"translation", ""},
                                      {"words", QJsonArray{}}});
    }
    const QJsonObject lyrics{{"version", 1},  {"source", "netease"}, {"timing", "line"},
                             {"offsetMs", 0}, {"plainText", ""},     {"lines", lyricLines}};
    backend.host.fixture = [&](QString route, QJsonObject parameters) {
        if (route.endsWith("/lyrics")) {
            return QJsonObject{{"body", QJsonObject{{"code", 200}, {"value", lyrics}}}};
        }
        if (route.endsWith("/detail")) {
            const auto item = parameters["args"].toArray().at(0).toObject();
            return QJsonObject{
                {"body",
                 QJsonObject{{"code", 200}, {"value", QJsonArray{item, QJsonArray{}, QJsonArray{}}}}}};
        }
        return QJsonObject{{"body", QJsonObject{{"code", 200}, {"value", QJsonObject{}}}}};
    };
    music.lists[0] = songs;
    music.lists[1] = songs;
    music.hasMore = {false, false, false, false, false};
    music.keyword = "本地测试";
    music.status = "离线界面验证";
    hud.reduced = true;
    hud.openModal("search");
    const auto refresh = [&] {
        // 固定展示夹具不随物理选中自动重新读取；点击动作仍走真实原生控制器。
        music.selectedPhysical = backend.scene.selection();
        backend.step(50);
        settle();
    };
    const auto capture = [&](QString name) {
        if (!output.isEmpty()) {
            QDir().mkpath(output);
            window->grabWindow().save(output + "/" + name + ".png");
        }
    };
    window->requestActivate();
    refresh();
    const double scale = window->height() / 1080.0;
    const double width = window->width() / scale;
    const auto wheel = [&](double x, double y, bool pixels) {
        const QPointF position(x * scale, y * scale);
        QWheelEvent event(position, window->mapToGlobal(position), pixels ? QPoint(0, -15) : QPoint(),
                          pixels ? QPoint() : QPoint(0, -120), Qt::NoButton, Qt::NoModifier,
                          Qt::NoScrollPhase, false);
        QCoreApplication::sendEvent(window, &event);
        refresh();
    };
    const auto click = [&](QString action) {
        for (const auto &value : backend.hits()) {
            const auto hit = value.toMap();
            if (hit.value("action").toString() != action) {
                continue;
            }
            const auto offset = hud.modal.isEmpty() || hit.value("fixed").toBool() ? 0 : hud.motion.offset;
            const QPointF position((hit.value("x").toDouble() + hit.value("width").toDouble() / 2) * scale,
                                   (hit.value("y").toDouble() + offset + hit.value("height").toDouble() / 2) *
                                       scale);
            for (auto type : {QEvent::MouseButtonPress, QEvent::MouseButtonRelease}) {
                QMouseEvent event(type, position, position, window->mapToGlobal(position), Qt::LeftButton,
                                  type == QEvent::MouseButtonPress ? Qt::LeftButton : Qt::NoButton,
                                  Qt::NoModifier);
                QCoreApplication::sendEvent(window, &event);
            }
            refresh();
            return true;
        }
        return false;
    };
    const auto hasAction = [&](QString action) {
        return std::any_of(hud.hits.begin(), hud.hits.end(),
                           [&](const QJsonValue &value) { return value.toObject()["action"] == action; });
    };
    const auto textY = [&](QString label) -> std::optional<double> {
        for (const auto &value : hud.commands) {
            const auto command = value.toArray();
            if (command.at(0) == "text" && command.at(1) == label) {
                return command.at(3).toDouble();
            }
        }
        return std::nullopt;
    };
    wheel(width * 0.7, 500, false);
    check(hud.listOffset == 1, "search row wheel routing");
    wheel(width * 0.7, 500, true);
    check(hud.listOffset == 2, "trackpad pixel wheel routing");
    auto input = window->findChild<QQuickItem *>("musicSearchInput");
    const auto bounds = hud.modalBounds(width);
    check(input && std::abs(input->x() / scale - bounds.x() - 53) < 0.01 &&
              std::abs(input->width() / scale - bounds.width() + 106) < 0.01 && input->hasActiveFocus(),
          "search input alignment and focus");
    check(click("music:page-next") && hud.listOffset == 7, "native next page click");
    check(click("music:page-prev") && hud.listOffset == 2, "native previous page click");
    capture("search");
    hud.openModal("saved");
    hud.musicCollection = 1;
    refresh();
    wheel(width / 2, 500, false);
    check(hud.listOffset == 1, "saved music row scrolling");
    QImage cover(512, 512, QImage::Format_RGBA8888_Premultiplied);
    cover.fill(QColor(78, 153, 197));
    QPainter painter(&cover);
    painter.setRenderHint(QPainter::Antialiasing);
    painter.setPen(QPen(QColor(213, 233, 231), 7));
    painter.drawEllipse(QRectF(52, 52, 408, 408));
    backend.glyphs()->text(painter, "RHINE LAB", 85, 112, 45, "bold", 1, Qt::white);
    backend.glyphs()->text(painter, "MUSIC ARCHIVE", 75, 355, 31, "demibold", 1, Qt::white);
    painter.end();
    backend.host.fixtureImage("fixture-disc", cover);
    hud.modal.clear();
    music.current = MusicData::item("playlist", "1",
                                    "《鸣潮》巡回演唱会「致予新世界」上海歌单 / 长标题布局验收", "测试歌手");
    music.tracks = songs;
    music.coverImage = "fixture-disc";
    backend.scene.review("detail");
    refresh();
    wheel(width * 0.5, 500, false);
    check(hud.trackOffset == 1, "playlist track row scrolling");
    capture("playlist");
    const auto originalWindowSize = window->size();
    window->resize(1152, 720);
    refresh();
    refresh();
    capture("playlist-16x10");
    window->resize(originalWindowSize);
    refresh();
    music.current = songs.first().toObject();
    music.current["title"] = "本地光盘模型验收";
    music.current["wiki"] = "本地生成封面 / 无网络访问";
    music.coverImage = "fixture-disc";
    music.detailLoading = false;
    hud.tab = "overview";
    refresh();
    capture("disc-case");
    backend.scene.openViewer();
    backend.scene.coverFront();
    refresh();
    check(backend.frame()["viewerReady"].toBool() && !backend.frame()["draws"].toArray().isEmpty(),
          "viewer loads actual model geometry");
    // 比较封面中心区域，避开 HUD；真实窗口不能继续采样资料库的旧景深纹理。
    const auto actualViewer = window->grabWindow().convertToFormat(QImage::Format_RGB32);
    const auto expectedViewer = renderReference(backend.root(), backend.frame(), backend.current(),
                                                backend.cover(), actualViewer.size(), backend.drawBuffers())
                                    .convertToFormat(QImage::Format_RGB32);
    // 中心区域必须有可见模型，防止相机或绘制故障让两张空画面再次通过。
    const auto clearColor = actualViewer.pixelColor(actualViewer.width() / 2, actualViewer.height() * .22);
    int modelPixels = 0;
    int modelSamples = 0;
    for (int y = actualViewer.height() * .3; y < actualViewer.height() * .7; y += 8) {
        for (int x = actualViewer.width() * .35; x < actualViewer.width() * .65; x += 8) {
            const auto pixel = actualViewer.pixelColor(x, y);
            const int contrast = qAbs(pixel.red() - clearColor.red()) +
                                 qAbs(pixel.green() - clearColor.green()) +
                                 qAbs(pixel.blue() - clearColor.blue());
            modelPixels += contrast > 16;
            ++modelSamples;
        }
    }
    check(modelSamples > 0 && modelPixels > modelSamples * .05, "viewer draws visible model pixels");
    int matchingPixels = 0;
    int sampledPixels = 0;
    if (actualViewer.size() == expectedViewer.size()) {
        for (int y = actualViewer.height() / 4; y < actualViewer.height() * .72; y += 8) {
            for (int x = actualViewer.width() / 5; x < actualViewer.width() * .8; x += 8) {
                const auto actualColor = actualViewer.pixelColor(x, y);
                const auto expectedColor = expectedViewer.pixelColor(x, y);
                const int difference = qAbs(actualColor.red() - expectedColor.red()) +
                                       qAbs(actualColor.green() - expectedColor.green()) +
                                       qAbs(actualColor.blue() - expectedColor.blue());
                matchingPixels += difference <= 24;
                ++sampledPixels;
            }
        }
    }
    if (!sampledPixels || matchingPixels <= sampledPixels * .95) {
        qWarning() << "Viewer GPU comparison:" << actualViewer.size() << expectedViewer.size()
                   << matchingPixels << sampledPixels;
        if (!output.isEmpty()) {
            actualViewer.save(output + "/viewer-actual.png");
            expectedViewer.save(output + "/viewer-expected.png");
        }
    }
    check(sampledPixels > 0 && matchingPixels > sampledPixels * .95,
          "viewer samples current scene texture after archive transition");
    if (!output.isEmpty()) {
        window->grabWindow().save(output + "/viewer-front.png");
    }
    backend.scene.coverFront(false);
    refresh();
    check(backend.frame()["eye"].toArray().at(2).toDouble() < 0, "disc rear camera");
    capture("disc-back");
    backend.scene.viewerAction("close");
    backend.step(51);
    hud.modal.clear();
    backend.scene.reduced(false);
    QJsonArray followSongs;
    for (int id : {501, 502}) {
        auto song = songs.first().toObject();
        song["id"] = QString::number(id);
        song["key"] = "netease:song:" + QString::number(id);
        song["title"] = "本地切歌 " + QString::number(id);
        followSongs.append(song);
        music.details[song["key"].toString()] = song;
    }
    player.queue = followSongs;
    player.current = followSongs.first().toObject();
    music.followPlayback(player.current);
    for (int index = 1; index <= 240; ++index) {
        backend.step(51 + index / 60.0);
    }
    player.current = followSongs.at(1).toObject();
    music.followPlayback(player.current);
    backend.step(55.01);
    check(music.current["id"] == "502" && music.directory && music.directory->index == 1 &&
              hud.frame["mode"] == "detail",
          "song change synchronizes upper detail and archive selection");
    check(backend.frame()["returningCards"].toInt() > 0, "song change returns outgoing disc");
    for (int index = 1; index <= 240; ++index) {
        backend.step(55.01 + index / 60.0);
    }
    capture("song-switch");
    music.directory.reset();
    player.current = {};
    backend.scene.reduced(true);
    for (const auto &kind : {QString("album"), QString("playlist"), QString("artist")}) {
        hud.openModal("search");
        music.searchKind = kind;
        music.current = MusicData::item(kind, "8", "本地分类检索", "测试歌手");
        refresh();
        check(!hasAction("music:play-loaded"), "search excludes background directory");
        capture("search-" + kind);
    }
    hud.openModal("search");
    hud.action("music:group:1");
    music.lists[0] = {};
    for (int index = 0; index < songs.size(); ++index) {
        auto song = songs.at(index).toObject();
        song["artists"] = QJsonArray{QJsonObject{{"id", QString::number(index / 10 + 10)},
                                                 {"name", "测试歌手 " + QString::number(index / 10)}}};
        music.lists[0].append(song);
    }
    music.changed();
    refresh();
    check(click("music:expand:artist%3A10"), "artist group native click");
    check(hud.activeGroup == "artist:10" && hud.rows(0).size() == 10, "group preserves song indices");
    check(click("music:group-back"), "group return native click");
    capture("artist-groups");
    for (const bool keyboard : {false, true}) {
        hud.modal.clear();
        auto directory = std::make_shared<MusicDirectory>();
        directory->item = MusicData::item("artist", "789658", "HOYO-MiX", "", "kugou");
        directory->parentPhysical = music.physicalSlots[0].first();
        directory->parentItem = songs.first().toObject();
        music.directory = directory;
        music.showDirectoryInfo();
        backend.scene.review("detail");
        refresh();
        if (keyboard) {
            QKeyEvent event(QEvent::KeyPress, Qt::Key_Escape, Qt::NoModifier);
            QCoreApplication::sendEvent(window, &event);
            refresh();
        } else {
            check(click("music:directory"), "empty artist return button");
        }
        check(!music.directory && !music.directoryInfo, "empty artist restores parent");
    }
    QTemporaryDir audioFixture;
    QFile audioFile(audioFixture.filePath("silent.wav"));
    check(audioFile.open(QIODevice::WriteOnly), "local audio fixture file");
    QDataStream wav(&audioFile);
    wav.setByteOrder(QDataStream::LittleEndian);
    constexpr quint32 bytes = 8000 * 2 * 4;
    wav.writeRawData("RIFF", 4);
    wav << quint32(36 + bytes);
    wav.writeRawData("WAVEfmt ", 8);
    wav << quint32(16) << quint16(1) << quint16(1) << quint32(8000) << quint32(16000) << quint16(2)
        << quint16(16);
    wav.writeRawData("data", 4);
    wav << bytes;
    wav.writeRawData(QByteArray(bytes, '\0').constData(), bytes);
    audioFile.close();
    backend.host.mediaControl("volume", 0);
    check(backend.host.mediaLoad(QUrl::fromLocalFile(audioFile.fileName()).toString()),
          "local audio source accepted");
    wait.restart();
    while (backend.host.mediaState().value("duration").toLongLong() == 0 && wait.elapsed() < 5000) {
        settle();
    }
    const auto decoded = backend.host.mediaState();
    check(decoded.value("duration").toLongLong() >= 3900 && decoded.value("error").toString().isEmpty(),
          "native PCM decode duration");
    backend.host.mediaControl("pause");
    settle();
    check(!backend.host.mediaState().value("playing").toBool(), "native pause");
    backend.host.mediaControl("seek", 1500);
    // 系统音频后端异步完成跳转；等待目标位置，不能用固定的一帧延迟判断。
    wait.restart();
    while (qAbs(backend.host.mediaState().value("position").toLongLong() - 1500) >= 100 &&
           wait.elapsed() < 3000) {
        settle();
    }
    const auto seekState = backend.host.mediaState();
    if (qAbs(seekState.value("position").toLongLong() - 1500) >= 100) {
        qWarning() << "Native seek state:" << seekState;
    }
    check(qAbs(seekState.value("position").toLongLong() - 1500) < 100, "native seek");
    backend.host.mediaControl("volume", .4);
    check(qAbs(backend.host.mediaState().value("volume").toDouble() - .4) < .01, "native volume");
    player.current = songs.first().toObject();
    player.queue = MusicData::slice(songs, 0, 10);
    player.index = 0;
    hud.openModal("player");
    refresh();
    check(click("player:mode") && player.mode == "one", "native playback mode click");
    check(click("player:remove:1") && player.queue.size() == 9, "native queue removal");
    const auto dragControl = [&](const std::optional<QRectF> &bounds, double fraction) {
        if (!bounds) {
            check(false, "player drag region exists");
            return;
        }
        const QPointF start((bounds->x() + bounds->width() * 0.2) * scale, bounds->center().y() * scale);
        const QPointF end((bounds->x() + bounds->width() * fraction) * scale, start.y());
        for (const auto type : {QEvent::MouseButtonPress, QEvent::MouseMove, QEvent::MouseButtonRelease}) {
            const auto position = type == QEvent::MouseButtonPress ? start : end;
            QMouseEvent event(type, position, position, window->mapToGlobal(position),
                              type == QEvent::MouseMove ? Qt::NoButton : Qt::LeftButton,
                              type == QEvent::MouseButtonRelease ? Qt::NoButton : Qt::LeftButton,
                              Qt::NoModifier);
            QCoreApplication::sendEvent(window, &event);
            settle();
        }
    };
    dragControl(hud.playerSeekRect, 0.5);
    wait.restart();
    while (std::abs(backend.host.mediaState()["position"].toLongLong() - 2000) >= 100 &&
           wait.elapsed() < 3000) {
        settle();
    }
    check(std::abs(backend.host.mediaState()["position"].toLongLong() - 2000) < 100,
          "QML seek reaches native decoder");
    dragControl(hud.playerVolumeRect, 0.6);
    check(std::abs(backend.host.mediaState()["volume"].toDouble() - 0.6) < 0.01, "QML volume reaches output");
    capture("player");
    player.lyrics.load(songs.first().toObject(), true);
    refresh();
    check(click("player:lyrics"), "native lyrics button");
    refresh();
    check(hud.lyricsMode && music.current["id"] == player.current["id"],
          "lyrics opens playing song immediately");
    check(textY("每一束光都落在这里").has_value(), "lyrics replaces detail card");
    capture("lyrics");
    check(click("player:lyric-line:1"), "native lyric seek click");
    wait.restart();
    while (std::abs(backend.host.mediaState()["position"].toLongLong() - 1000) >= 100 &&
           wait.elapsed() < 3000) {
        settle();
    }
    check(std::abs(backend.host.mediaState()["position"].toLongLong() - 1000) < 100, "lyric seeks decoder");
    backend.action("player:lyrics-follow");
    check(player.lyrics.index == 1, "lyrics follows native seek");
    backend.action("player:lyrics-earlier");
    refresh();
    check(player.lyrics.offsetMs == 200 && textY("已提前 0.2s").has_value(),
          "lyric offset and direction label");
    player.lyrics.load(songs.first().toObject());
    refresh();
    check(player.lyrics.offsetMs == 0, "cached lyrics reset offset");
    const auto beforeScroll = textY("我们听见远处的回声");
    backend.wheel(width * 0.7, 500, -2, true);
    refresh();
    const auto afterScroll = textY("我们听见远处的回声");
    check(beforeScroll && afterScroll && *beforeScroll > *afterScroll && *beforeScroll - *afterScroll < 10,
          "sub-row pixels scroll lyrics continuously");
    backend.action("player:lyrics-close");
    backend.host.mediaControl("stop");
    player.stop();
    hud.openModal("discover");
    music.discover->items = MusicData::slice(songs, 0, 10);
    music.discover->status = "本地发现页面验收";
    refresh();
    capture("discover");
    hud.openModal("login");
    music.loginMethod = "email";
    refresh();
    auto accountField = window->findChild<QQuickItem *>("accountField");
    auto passwordField = window->findChild<QQuickItem *>("passwordField");
    check(accountField && passwordField && accountField->isVisible() && passwordField->isVisible() &&
              passwordField->property("echoMode").toInt() == 2,
          "native login and masked password");
    capture("login");
    hud.openModal("settings");
    refresh();
    check(hasAction("provider") && !hasAction("provider:qq"), "settings has one provider entry");
    capture("settings");
    music.switchProvider("qq");
    hud.openModal("discover");
    music.discover->items = MusicData::slice(songs, 0, 6);
    refresh();
    capture("qq-discover");
    hud.openModal("login");
    music.loginMethod = "wechat";
    refresh();
    check(!accountField->isVisible() && !passwordField->isVisible(), "QQ QR hides password form");
    capture("qq-login");
    hud.openModal("settings");
    refresh();
    check(click("provider") && hasAction("provider:netease") && hasAction("provider:qq") &&
              hasAction("provider:kugou"),
          "three directly selectable providers");
    capture("providers");
    music.switchProvider("kugou");
    hud.openModal("login");
    music.loginMethod = "qr";
    refresh();
    check(hasAction("music:kugou-edition:standard") && hasAction("music:kugou-edition:lite"),
          "Kugou app editions");
    capture("kugou-login");
    music.switchProvider("kugou", "lite");
    hud.openModal("login");
    refresh();
    check(music.kugouEdition == "lite" && music.providerName() == "酷狗概念版", "Kugou concept edition");
    capture("kugou-concept-login");
    hud.openModal("settings");
    refresh();
    const auto previousVisibility = window->visibility();
    backend.action("window:fullscreen");
    wait.restart();
    while (window->visibility() != QWindow::FullScreen && wait.elapsed() < 10000) {
        settle();
    }
    check(window->visibility() == QWindow::FullScreen, "native fullscreen");
    backend.action("window:fullscreen");
    wait.restart();
    while (window->visibility() != previousVisibility && wait.elapsed() < 10000) {
        settle();
    }
    check(window->visibility() == previousVisibility, "restore window mode");
    window->resize(originalWindowSize);
    player.stop();
    hud.modal.clear();
    hud.motion.set(true, 0, true);
    backend.scene.review("archive");
    backend.scene.setMode("archive");
    backend.wake();
    wait.restart();
    while (!backend.performance()["idle"].toBool() && wait.elapsed() < 15000) {
        settle();
    }
    check(backend.performance()["idle"].toBool(), "native scene converges into idle");
    const auto idleSteps = backend.performance()["steps"].toULongLong();
    const auto idleFrames = backend.performance()["renderFrames"].toULongLong();
    for (int index = 0; index < 8; ++index) {
        settle();
    }
    check(backend.performance()["steps"].toULongLong() == idleSteps &&
              backend.performance()["renderFrames"].toULongLong() == idleFrames,
          "idle has zero CPU steps and GPU renders");
    backend.scene.theme(true);
    backend.host.invalidate();
    settle();
    check(backend.performance()["steps"].toULongLong() > idleSteps,
          "background scene change wakes scheduler");
    backend.scene.theme(false);
    window->hide();
    settle();
    const auto hiddenSteps = backend.performance()["steps"].toULongLong();
    backend.host.invalidate();
    for (int index = 0; index < 4; ++index) {
        settle();
    }
    check(!backend.performance()["timerActive"].toBool() &&
              backend.performance()["steps"].toULongLong() == hiddenSteps,
          "hidden window stays asleep");
    window->show();
    // Windows 的窗口曝光异步完成；等待实际推进，避免固定 150 ms 把正常恢复误判为失败。
    wait.restart();
    while (backend.performance()["steps"].toULongLong() <= hiddenSteps && wait.elapsed() < 8000) {
        settle();
    }
    check(backend.performance()["steps"].toULongLong() > hiddenSteps, "window restore refreshes state");
    backend.setVisible(false);
    hud.modal.clear();
    backend.scene.review("detail");
    backend.setVisible(true);
    const auto cachedSelection = [&](int index) {
        music.current = MusicData::item("song", QString::number(index), "缓存回选验收", "本地");
        music.current["key"] = "cache-" + QString::number(index);
        music.coverImage = "fixture-disc";
        music.selectedPhysical = backend.scene.selection();
        backend.step(70);
        settle();
        // 资源计数由渲染线程提交；同步抓取本帧后再断言，不能拿排队中的旧帧计数比较。
        check(!window->grabWindow().isNull(), "cache selection reaches the GPU");
    };
    cachedSelection(0);
    cachedSelection(1);
    cachedSelection(0);
    const auto warmedResources = backend.performance()["gpuResources"].toULongLong();
    for (int index = 0; index < 20; ++index) {
        cachedSelection(index % 2);
    }
    check(warmedResources > 0 && backend.performance()["gpuResources"].toULongLong() == warmedResources,
          "cover cache hits keep GPU resources stable");
    backend.scene.diagnostics(false);
    const auto beforeBindings = backend.performance()["bindingCreations"].toULongLong();
    const auto beforeUploads = backend.performance()["coverUploads"].toULongLong();
    cachedSelection(99);
    const auto newBindings = backend.performance()["bindingCreations"].toULongLong() - beforeBindings;
    check(newBindings > 0 && newBindings <= 8, "new song updates only texture bindings");
    check(backend.performance()["coverUploads"].toULongLong() == beforeUploads,
          "album cover shares uploaded texture");
    // 多首新曲填满纹理缓存后，隐藏窗口须销毁 GPU 对象；恢复须还原同一幅冻结画面。
    for (int i = 100; i < 135; ++i) {
        cachedSelection(i);
    }
    check(backend.performance().value("gpuMusicTextureBytes").toULongLong() <= 24 * 1024 * 1024,
          "settled song texture cache respects the byte budget");
    const auto beforeRelease = window->grabWindow();
    const auto frameBeforeRelease = backend.frame();
    const auto buffersBeforeRelease = backend.drawBuffers();
    const auto commandsBeforeRelease = backend.commands();
    const auto selectedBeforeRelease = backend.current();
    window->hide();
    wait.restart();
    while (backend.performance().value("gpuResources").toULongLong() != 0 && wait.elapsed() < 8000) {
        settle();
    }
    check(backend.performance().value("gpuResources").toULongLong() == 0,
          "sustained background releases the graphics scene");
    check(!backend.performance().value("timerActive").toBool(), "resource cleanup keeps visual timer asleep");
    window->show();
    wait.restart();
    while (backend.performance().value("gpuResources").toULongLong() == 0 && wait.elapsed() < 8000) {
        settle();
    }
    settle();
    check(backend.current() == selectedBeforeRelease, "graphics rebuild preserves current song");
    qInfo() << "Graphics restore exposure:" << window->isVisible() << window->isExposed()
            << window->visibility() << backend.performance().value("visible")
            << backend.performance().value("gpuResources");
    check(backend.performance().value("gpuResources").toULongLong() > 0,
          "restored window rebuilds GPU resources");
    const auto afterRelease = window->grabWindow();
    if (!output.isEmpty()) {
        beforeRelease.save(output + "/background-before.png");
        afterRelease.save(output + "/background-after.png");
        for (const auto &entry : {qMakePair(QString("background-before.json"), frameBeforeRelease),
                                  qMakePair(QString("background-after.json"), backend.frame())}) {
            QFile file(output + "/" + entry.first);
            if (file.open(QIODevice::WriteOnly)) {
                file.write(QJsonDocument(entry.second).toJson());
            }
        }
    }
    auto frameBefore = frameBeforeRelease;
    auto frameAfter = backend.frame();
    for (const auto &key : {"time", "boot"}) {
        frameBefore.remove(key);
        frameAfter.remove(key);
    }
    check(frameBefore == frameAfter, "graphics rebuild preserves exact scene and material data");
    check(commandsBeforeRelease == backend.commands(), "graphics rebuild preserves exact HUD commands");
    const auto buffersAfterRelease = backend.drawBuffers();
    bool buffersMatch = buffersBeforeRelease.size() == buffersAfterRelease.size();
    for (auto it = buffersBeforeRelease.begin(); it != buffersBeforeRelease.end(); ++it) {
        const auto after = buffersAfterRelease.value(it.key());
        buffersMatch &= it->matrices == after.matrices && it->themes == after.themes;
    }
    check(buffersMatch, "graphics rebuild preserves exact matrix and theme bytes");
    int changedPixels = 0;
    check(equivalentGpuPixels(beforeRelease, afterRelease, changedPixels),
          "background release and rebuild preserve the frozen window pixels");
    qInfo() << "[ui] Rebuild RGB8 rounding pixels:" << changedPixels;
    if (!output.isEmpty()) {
        QFile metrics(output + "/performance.json");
        if (metrics.open(QIODevice::WriteOnly)) {
            metrics.write(QJsonDocument::fromVariant(backend.performance()).toJson());
        }
    }
    if (ok) {
        qInfo() << "Native QML scrolling, paging and search input checks passed";
    }
    return ok ? 0 : 1;
}
