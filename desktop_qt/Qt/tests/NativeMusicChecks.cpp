#include "MusicLibrary.h"
#include "MusicData.h"
#include "MusicDiscover.h"
#include <QCoreApplication>
#include <QDataStream>
#include <QElapsedTimer>
#include <QFile>
#include <QJsonDocument>
#include <QThread>
#include <QTemporaryDir>
#include <QUrl>

namespace {
bool waitFor(const std::function<bool()> &ready, int timeout = 3000) {
    QElapsedTimer elapsed;
    elapsed.start();
    while (!ready() && elapsed.elapsed() < timeout) {
        QCoreApplication::processEvents();
        QThread::msleep(1);
    }
    return ready();
}

QJsonObject song(QString id, QString title = "本地歌曲") {
    auto value = MusicData::item("song", id, title, "测试歌手");
    value["albumID"] = "7";
    value["album"] = "测试专辑";
    value["duration"] = 180000;
    value["cover"] = "https://music.126.net/native-fixture.jpg";
    return value;
}

QJsonObject lyrics() {
    return {{"version", 1},
            {"timing", "line"},
            {"offsetMs", 0},
            {"plainText", "第一句\n第二句"},
            {"lines", QJsonArray{QJsonObject{{"startMs", 1000}, {"text", "第一句"}},
                                 QJsonObject{{"startMs", 3000}, {"text", "第二句"}}}}};
}
}

/** 原生业务回归只调用 Qt 类型和本地响应，不用脚本对象充当资料库、播放器或歌词模型。 */
bool runNativeMusicChecks(const QString &root) {
    QFile file(root + "/slots.json");
    if (!file.open(QIODevice::ReadOnly)) {
        return false;
    }
    Host host(root, true);
    MusicLibrary library(&host, QJsonDocument::fromJson(file.readAll()).object());
    QTemporaryDir audioFixture;
    QFile audio(audioFixture.filePath("native-silent.wav"));
    if (!audio.open(QIODevice::WriteOnly)) {
        return false;
    }
    QDataStream wav(&audio);
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
    audio.close();
    const auto audioURL = QUrl::fromLocalFile(audio.fileName()).toString();
    host.mediaControl("volume", 0);
    bool ok = true;
    const auto check = [&](bool value, const char *name) {
        if (!value) {
            qCritical() << "Native music regression:" << name;
        }
        ok &= value;
    };
    int nativeSearches = 0;
    int details = 0;
    int mutations = 0;
    host.fixture = [&](QString route, QJsonObject parameters) {
        const auto args = parameters["args"].toArray();
        QJsonValue value;
        if (route.endsWith("/search")) {
            ++nativeSearches;
            const auto query = args.at(0).toString();
            value = QJsonObject{
                {"items", QJsonArray{song("1", query)}}, {"total", 1}, {"rawCount", 1}, {"more", false}};
        } else if (route.endsWith("/lyrics")) {
            value = lyrics();
        } else if (route.endsWith("/songs")) {
            // 单个数组参数仍须保留嵌套层级，不能被 Qt 版本或编译器构造成参数列表本身。
            check(args.size() == 1 && args.first().isArray(), "song IDs remain a nested IPC argument");
            QJsonArray songs;
            for (const auto &id : args.at(0).toArray()) {
                if (id != "missing") {
                    songs.append(song(id.toString()));
                }
            }
            value = songs;
        } else if (route.endsWith("/detail")) {
            ++details;
            const auto entry = args.at(0).toObject();
            if (entry["kind"] == "song") {
                value = QJsonArray{song(entry["id"].toString()), QJsonArray{}, QJsonArray{}};
            } else {
                auto info = entry;
                info["trackCount"] = 3;
                value =
                    QJsonArray{info, QJsonArray{song("1"), song("2")}, QJsonArray{"1", "missing", "2", "3"}};
            }
        } else if (route.endsWith("/wiki")) {
            value = "本地百科";
        } else if (route.endsWith("/playback")) {
            value = QJsonObject{{"url", audioURL}};
        } else if (route.endsWith("/account")) {
            value = QJsonArray{"42", "本地账号"};
        } else if (route.endsWith("/likedIDs")) {
            value = QJsonArray{"1", "missing", "2"};
        } else if (route.endsWith("/userPlaylists")) {
            auto owned = MusicData::item("playlist", "8", "本人歌单");
            owned["creatorID"] = "42";
            const auto collected = MusicData::item("playlist", "9", "收藏歌单");
            value = QJsonObject{{"items", QJsonArray{owned, collected}}, {"rawCount", 2}, {"more", false}};
        } else if (route == "/like" || route == "/playlist/name/update" || route == "/playlist/tracks") {
            ++mutations;
            return QJsonObject{{"body", QJsonObject{{"code", 200}}}};
        } else if (route == "/login/cellphone") {
            return QJsonObject{{"body", QJsonObject{{"code", 200}}},
                               {"cookies", QJsonArray{"MUSIC_U=fixture-native"}}};
        } else if (route == "/personalized") {
            return QJsonObject{
                {"body", QJsonObject{{"code", 200},
                                     {"result", QJsonArray{QJsonObject{{"id", 8}, {"name", "原生推荐"}}}}}}};
        } else {
            return QJsonObject{{"body", QJsonObject{{"code", 200}}}};
        }
        return QJsonObject{{"body", QJsonObject{{"code", 200}, {"value", value}}}};
    };
    QObject::connect(&library, &MusicLibrary::modeRequested, &library,
                     [&](QString mode) { library.frame["mode"] = mode; });
    QObject::connect(&library, &MusicLibrary::selectionRequested, &library,
                     [&](int selected, QJsonObject) { library.frame["selected"] = selected; });

    library.search("旧查询");
    library.search("新查询");
    check(waitFor([&] { return !library.searchLoading; }), "search finishes");
    check(library.current["title"] == "新查询" && library.totals[0] == 1, "latest search owns selection");
    library.search("还未完成");
    library.search(" ");
    QCoreApplication::processEvents();
    check(!library.searchLoading && library.status == "请输入 1–100 字关键词",
          "invalid query cancels pending search");
    library.choose(MusicData::item("song", "10"));
    library.choose(song("11"));
    check(waitFor([&] { return !library.detailLoading; }), "metadata selection settles");
    check(library.current["id"] == "11", "old details cannot replace a new song");

    QJsonArray many;
    for (int i = 0; i < 2000; ++i) {
        many.append(song(QString::number(i + 1)));
    }
    library.lists[0] = many;
    library.selectedLane = 0;
    library.selectedPhysical = library.physicalSlots[0].value(1);
    library.offsets[0] = 0;
    library.hasMore[0] = false;
    library.next(-25);
    check(library.offsets[0] == 1976, "large reverse deltas preserve logical and physical rows");
    library.setGroupView("分组", {5, 7}, 0);
    check(library.libraryTotal() == 2 && library.sourceItems(0).at(1).toObject()["id"] == "8",
          "native grouped view uses source indices");
    library.setGroupView({}, {}, 0);

    library.enterDirectory(MusicData::item("playlist", "8", "本地目录"));
    check(waitFor([&] { return !library.directoryLoading; }), "directory detail finishes");
    check(library.directory && library.directory->ids.size() == 4 && library.directory->cursor == 3,
          "directory retains sparse complete IDs");
    const auto parent = library.directory;
    library.enterDirectory(MusicData::item("album", "7", "嵌套目录"));
    check(waitFor([&] { return !library.directoryLoading; }), "nested directory finishes");
    library.leaveDirectory();
    check(library.directory == parent, "return restores parent directory identity");
    library.loadDirectoryPage(2);
    check(waitFor([&] { return !library.directoryLoading; }), "directory page finishes");
    check(library.directory->cursor == 4 && library.directory->songs.size() == 3 &&
              library.current["id"] == "3",
          "sparse IDs consumed once and later selection restored");
    const auto queue = library.directoryQueue();
    check(queue.size() == 4 && queue.at(1).toObject()["deferred"].toBool(), "queue preserves unloaded IDs");
    library.leaveDirectory();
    library.enterDirectory(MusicData::item("playlist", "9", "迟到目录"));
    library.leaveDirectory();
    QCoreApplication::processEvents();
    check(!library.directory, "closed directory cannot reopen from a delayed response");

    library.uid = "42";
    library.likedIDs.reset();
    library.hasMore[1] = true;
    library.loadMoreSource(1);
    check(waitFor([&] { return !library.personalLoading; }), "liked songs finish");
    check(library.totals[1] == 3 && library.lists[1].size() == 2 && !library.hasMore[1],
          "unavailable liked IDs do not cause retry loops");
    library.hasMore[2] = true;
    library.loadMoreSource(2);
    check(waitFor([&] { return !library.personalLoading; }), "playlists finish");
    check(library.lists[2].size() == 1 && library.lists[3].size() == 1,
          "owned playlists require creator identity");
    library.current = song("1");
    library.like();
    check(waitFor([&] { return !library.writeLoading; }), "like mutation finishes");
    check(MusicData::indexOf(*library.likedIDs, "1") < 0, "like mutation updates IDs");
    bool renamed = false;
    library.playlistForm("rename", "重命名", "8", [&](bool value) { renamed = value; });
    check(waitFor([&] { return renamed; }), "owned rename succeeds");
    check(library.lists[2].first().toObject()["title"] == "重命名", "renamed title retained");
    const auto before = mutations;
    library.playlistForm("rename", "非法", "other");
    check(mutations == before, "cannot edit another user's playlist");

    library.player.play(song("1"), QJsonArray{song("1"), song("2")});
    check(waitFor([&] { return !library.player.loading; }), "native playback source finishes");
    check(!library.player.failed && library.player.queue.size() == 2, "native playback prepares the queue");
    check(waitFor([&] { return library.player.lyrics.status == "ready"; }), "native lyrics finish");
    library.player.lyrics.sync(1500);
    check(library.player.lyrics.index == 0, "lyrics locate the first line");
    library.player.lyrics.adjustOffset(2000);
    check(library.player.lyrics.index == 1, "lyrics offset updates the shared index");
    library.player.lyrics.sync(0);
    check(library.player.lyrics.index == 0, "backward seeking updates lyrics");
    library.player.next();
    check(waitFor([&] { return !library.player.loading; }) && library.player.current["id"] == "2",
          "next song uses the native queue");
    library.player.stop();
    check(library.player.current.isEmpty() && library.player.lyrics.document().isEmpty(),
          "stop clears player and lyrics");

    library.discover->load("playlists");
    check(waitFor([&] { return !library.discover->loading; }), "native discovery finishes");
    check(library.discover->items.size() == 1 &&
              library.discover->items.first().toObject()["title"] == "原生推荐",
          "discovery normalizes metadata");
    library.passwordLogin("phone", "13800000000", "fixture-password");
    check(waitFor([&] { return !library.accountLoading; }) && library.uid == "42",
          "native password login confirms account");
    check(library.identityName() == "本地账号", "native account identity retained");
    library.logout();
    check(library.uid.isEmpty() && library.lists[1].isEmpty() && library.lists[2].isEmpty() &&
              library.lists[3].isEmpty(),
          "logout clears private collections");
    library.switchProvider("qq");
    check(library.provider == "qq" && library.player.queue.isEmpty() && library.directory == nullptr,
          "provider switch clears old native state");
    library.switchProvider("kugou", "lite");
    check(library.kugouEdition == "lite" && library.accountKey() == "kugou-lite",
          "Kugou editions retain separate account keys");
    check(nativeSearches > 0 && details > 0 && mutations >= 2,
          "native business exercises the real callback boundary");
    host.shutdown();
    qInfo() << "Native library, directories, account, playback, lyrics, mutations and discovery:"
            << (ok ? "passed" : "FAILED");
    return ok;
}
