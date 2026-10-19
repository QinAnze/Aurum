#include "Host.h"
#include <QCoreApplication>
#include <QElapsedTimer>
#include <QThread>

namespace {
bool waitFor(const std::function<bool()> &ready) {
    QElapsedTimer elapsed;
    elapsed.start();
    while (!ready() && elapsed.elapsed() < 2000) {
        QCoreApplication::processEvents();
        QThread::msleep(1);
    }
    return ready();
}
}

/** 不创建脚本引擎，验证原生业务可直接使用缓存、账号代数、封面和官方播放边界。 */
bool runNativeHostChecks(const QString &root) {
    Host host(root, true);
    int requests = 0;
    host.fixture = [&](QString, QJsonObject parameters) {
        ++requests;
        return QJsonObject{{"body", QJsonObject{{"code", 200}, {"query", parameters["keywords"]}}}};
    };
    int replies = 0;
    bool ok = true;
    const auto receive = [&](QJsonObject response, QString error) {
        ++replies;
        ok &= error.isEmpty() && response["body"].toObject()["query"] == "native" &&
              response["_epoch"].toInt() == host.epoch;
    };
    host.requestJson("/search", {{"keywords", "native"}}, receive);
    host.requestJson("/search", {{"keywords", "native"}}, receive);
    ok &= waitFor([&] { return replies == 2; }) && requests == 1;
    host.requestJson("/search", {{"keywords", "native"}}, receive);
    ok &= waitFor([&] { return replies == 3; }) && requests == 1;

    const auto originalEpoch = host.epoch;
    bool staleReceived = false;
    host.requestJson("/login/qr/check", {}, [&](QJsonObject response, QString error) {
        staleReceived = error.isEmpty() && response["_epoch"].toInt() == originalEpoch &&
                        response["_epoch"].toInt() != host.epoch;
    });
    host.logout();
    ok &= waitFor([&] { return staleReceived; });

    QImage image(2, 2, QImage::Format_RGBA8888);
    image.fill(Qt::red);
    const QString cover = "https://music.126.net/native-fixture.jpg?param=512y512";
    host.fixtureImage(cover, image);
    bool coverReady = false;
    host.loadCover("https://music.126.net/native-fixture.jpg",
                   [&](QString key) { coverReady = key == cover && host.image(key) == image; });
    ok &= coverReady;
    bool invalidId = false;
    bool official = false;
    host.playOfficial("invalid", [&](QString error) { invalidId = error == "请先选择一首歌曲"; });
    host.playOfficial("42", [&](QString value) { official = value == "OFFLINE_PLAY:42"; });
    ok &= invalidId && official;

    bool delayed = false;
    host.schedule(0, [&] { delayed = true; });
    ok &= !delayed && waitFor([&] { return delayed; });
    bool afterShutdown = false;
    host.schedule(0, [&] { afterShutdown = true; });
    host.shutdown();
    QCoreApplication::processEvents();
    ok &= !afterShutdown;
    qInfo() << "Native Host callbacks, request merging, cache, epoch, images and shutdown:"
            << (ok ? "passed" : "FAILED");
    return ok;
}
