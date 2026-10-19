#include "Engine.h"
#include "DiscGeometry.h"
#include "RhiScene.h"
#include <QCoreApplication>
#include <QDir>
#include <QEvent>
#include <QEventLoop>
#include <QFile>
#include <QJsonDocument>
#include <QPainter>
#include <QThread>
#include <algorithm>
#include <cmath>
#include <cstring>
bool runNativeHostChecks(const QString &root);
bool runNativeMusicChecks(const QString &root);
bool runGpuReferenceCheck(const QImage &expected, const QImage &actual);

/** 建立纯原生音乐、HUD 和场景状态；Qt 定时器只在输入或动画尚未收束时运行。 */
Engine::Engine(QString path, bool offline, QObject *parent)
    : QObject(parent), host(path, offline), scene(path), m_glyphs(path) {
    const auto content = QJsonDocument::fromJson(host.read("slots.json").toUtf8()).object();
    app = std::make_unique<NativeApplication>(&host, &m_glyphs, &scene, content);
    app->initialize();
    connect(&host, &Host::invalidated, this, [this] { wake(false); });
    connect(&host, &Host::mediaChanged, this, &Engine::pollMedia, Qt::QueuedConnection);
    connect(&host, &Host::mediaAction, this, [this](QString value) {
        app->mediaAction(value);
        wake();
    });
    clock.start();
    timer.setTimerType(Qt::PreciseTimer);
    connect(&timer, &QTimer::timeout, this, &Engine::tick);
    mediaTimer.setInterval(1000);
    connect(&mediaTimer, &QTimer::timeout, this, &Engine::pollMedia);
    if (!offline) {
        start();
    }
}
Engine::~Engine() {
    timer.stop();
    mediaTimer.stop();
    app.reset();
    host.shutdown();
}
bool Engine::ready() const {
    return scene.ready();
}
namespace {
// 只有低于实际显示精度的浮点尾差才可视为收束，时间和诊断计数不参与画面失效。
bool equivalent(const QJsonValue &a, const QJsonValue &b) {
    if (a.type() != b.type()) {
        return false;
    }
    if (a.isDouble()) {
        return qAbs(a.toDouble() - b.toDouble()) <= 0.00001;
    }
    if (a.isArray()) {
        auto x = a.toArray();
        auto y = b.toArray();
        if (x.size() != y.size()) {
            return false;
        }
        for (int i = 0; i < x.size(); ++i) {
            if (!equivalent(x[i], y[i])) {
                return false;
            }
        }
        return true;
    }
    if (a.isObject()) {
        auto x = a.toObject();
        auto y = b.toObject();
        if (x.keys() != y.keys()) {
            return false;
        }
        for (auto it = x.begin(); it != x.end(); ++it) {
            if (!equivalent(it.value(), y[it.key()])) {
                return false;
            }
        }
        return true;
    }
    return a == b;
}
bool equivalent(const QByteArray &a, const QByteArray &b) {
    if (a == b) {
        return true;
    }
    if (a.size() != b.size()) {
        return false;
    }
    for (qsizetype i = 0; i + 4 <= a.size(); i += 4) {
        float x;
        float y;
        memcpy(&x, a.constData() + i, 4);
        memcpy(&y, b.constData() + i, 4);
        if (qAbs(x - y) > 0.00001f) {
            return false;
        }
    }
    return true;
}
}
bool Engine::eventFilter(QObject *watched, QEvent *event) {
    // 原生文本框和滑块也属于用户输入，不能只依赖资料库 MouseArea 的事件。
    switch (event->type()) {
    case QEvent::MouseButtonPress:
        m_pressed = true;
        wake();
        break;
    case QEvent::MouseButtonRelease:
        m_pressed = false;
        wake();
        break;
    case QEvent::MouseMove:
    case QEvent::Wheel:
    case QEvent::KeyPress:
    case QEvent::TouchBegin:
    case QEvent::TouchUpdate:
    case QEvent::TouchEnd:
        wake();
        break;
    default:
        break;
    }
    return QObject::eventFilter(watched, event);
}
void Engine::start() {
    m_started = true;
    wake(false);
}
QVariantMap Engine::performance() const {
    return {{"idle", m_sleeping},
            {"sceneSleeping", m_sceneSleeping},
            {"visible", m_visible},
            {"steps", qulonglong(m_steps)},
            {"sceneUpdates", qulonglong(m_sceneUpdates)},
            {"hudUpdates", qulonglong(m_hudUpdates)},
            {"renderFrames", qulonglong(m_renderFrames.load(std::memory_order_relaxed))},
            {"gpuResources", qulonglong(m_gpuResources.load(std::memory_order_relaxed))},
            {"bindingCreations", qulonglong(m_bindingCreations.load(std::memory_order_relaxed))},
            {"gpuMusicTextureBytes", qulonglong(m_musicTextureBytes.load(std::memory_order_relaxed))},
            {"coverUploads", qulonglong(m_coverUploads.load(std::memory_order_relaxed))},
            {"gpuDrawCalls", qulonglong(m_lastDrawCalls.load(std::memory_order_relaxed))},
            {"timerActive", timer.isActive()}};
}
void Engine::wake(bool input) {
    const bool wasSleeping = m_sleeping;
    const auto now = clock.elapsed();
    if (input) {
        m_lastInput = now;
        m_sceneSleeping = false;
        m_stableFrames = 0;
        scene.energyIdle(false);
    } else if (scene.changed()) {
        m_sceneSleeping = false;
        m_stableFrames = 0;
    }
    m_sleeping = !m_visible;
    if (wasSleeping && !m_sleeping) {
        emit stateChanged();
    }
    if (m_started && m_visible && !timer.isActive()) {
        // 恢复时接续视觉时钟，不能把整段待机时间推进到弹簧和拖动惯性中。
        m_lastTick = now;
        timer.start(16);
    }
}
void Engine::setVisible(bool value) {
    if (m_visible == value) {
        return;
    }
    m_visible = value;
    if (!value) {
        flushPointer();
        app->pointer("pointercancel", 0, 0);
        m_pressed = m_wheelPending = false;
        m_wheelDelta = m_wheelSteps = 0;
        m_wheelDistance = 0;
        timer.stop();
        m_sleeping = true;
    } else {
        host.restoreMemoryBudget();
        wake(false);
        emit sceneUpdated();
        emit hudUpdated();
    }
    emit stateChanged();
}
/**
 * 隐藏窗口持续一段时间后释放可重建缓存，不改变音乐、账号或尚未完成的动画。
 */
void Engine::trimMemory() {
    if (m_visible) {
        return;
    }
    QStringList retainedImages{m_cover};
    for (const auto &value : m_commands) {
        const auto command = value.toArray();
        if (command[0].toString() == "image") {
            retainedImages << command[1].toString();
        }
    }
    host.trimMemory(retainedImages);
    scene.trimMemory();
}
void Engine::pollMedia() {
    app->poll(clock.elapsed() / 1000.0, true);
    const auto &player = app->music.player;
    const bool active = player.loading || player.state["playing"].toBool();
    if (active && !mediaTimer.isActive()) {
        mediaTimer.start();
    }
    if (!active) {
        mediaTimer.stop();
    }
}
void Engine::flushPointer() {
    if (!m_pointerPending) {
        return;
    }
    m_pointerPending = false;
    app->pointer("pointermove", m_pointerX, m_pointerY);
}
/**
 * 推进本帧动画并决定是否继续调度。
 * 状态收束后允许待机，输入和后台数据失效会重新唤醒。
 */
void Engine::tick() {
    const auto now = clock.elapsed();
    m_animationTime += qMin<qint64>(now - m_lastTick, 50) / 1000.;
    m_lastTick = now;
    flushPointer();
    if (m_wheelPending) {
        const int steps = int(m_wheelSteps);
        app->hud.wheel(m_wheelX, m_wheelY, m_wheelDelta, steps, m_wheelDistance);
        m_wheelSteps -= steps;
        m_wheelPending = false;
        m_wheelDelta = 0;
        m_wheelDistance = 0;
    }
    if (now - m_lastInput >= 750 && !m_pressed) {
        scene.energyIdle(true);
    }
    step(m_animationTime);
    if (now - m_lastInput >= 750 && !m_pressed && m_sceneSleeping && !scene.changed() &&
        !app->hud.animating(m_animationTime) && m_frame["mode"] != "boot") {
        timer.stop();
        m_sleeping = true;
        emit stateChanged();
    }
}
void Engine::resize(double width, double height) {
    if (height <= 0 || (m_width == width && m_height == height)) {
        return;
    }
    m_width = width;
    m_height = height;
    scene.resize(width / (height / 1080), 1080);
    wake();
}
void Engine::action(QString value) {
    // 窗口模式由 Qt 原生窗口处理，不进入音乐状态或场景动画。
    if (value == "window:fullscreen") {
        toggleFullscreen();
        return;
    }
    app->hud.action(value);
    pollMedia();
    wake();
}
/**
 * 将输入控件的原始数据转换为原生业务操作；密码不写入公开状态。
 */
void Engine::submitForm(QString account, QString password) {
    QJsonObject values;
    if (app->hud.modal == "login") {
        values = {{"account", account}, {"password", password}};
    } else {
        values = {{"name", account}};
    }
    app->hud.form(values);
    wake();
}
void Engine::setWindow(QQuickWindow *window) {
    m_window = window;
}
void Engine::toggleFullscreen() {
    if (!m_window) {
        return;
    }
    if (m_window->visibility() == QWindow::FullScreen) {
        m_window->setVisibility(m_windowedVisibility);
    } else {
        m_windowedVisibility =
            m_window->visibility() == QWindow::Maximized ? QWindow::Maximized : QWindow::Windowed;
        m_window->showFullScreen();
    }
}
bool Engine::keyEvent(int keyCode, int modifiers, QString text) {
    switch (keyCode) {
    case Qt::Key_MediaTogglePlayPause:
    case Qt::Key_MediaPlay:
    case Qt::Key_MediaPause:
        action("player:toggle");
        return true;
    case Qt::Key_MediaNext:
        action("player:next");
        return true;
    case Qt::Key_MediaPrevious:
        action("player:prev");
        return true;
    case Qt::Key_Left:
        text = "ArrowLeft";
        break;
    case Qt::Key_Right:
        text = "ArrowRight";
        break;
    case Qt::Key_Up:
        text = "ArrowUp";
        break;
    case Qt::Key_Down:
        text = "ArrowDown";
        break;
    case Qt::Key_Return:
    case Qt::Key_Enter:
        text = "Enter";
        break;
    case Qt::Key_Escape:
        text = "Escape";
        break;
    default:
        break;
    }
    if (text.isEmpty()) {
        return false;
    }
    // Qt 在 macOS 将 ControlModifier 映射到命令键。
    key(text, modifiers & Qt::ControlModifier);
    return true;
}
void Engine::searchAccepted(QString text, int modifiers) {
    if (modifiers & Qt::ControlModifier) {
        key("Enter", true);
    } else {
        query(text);
    }
}
void Engine::wheelInput(double x, double y, double pixelDelta, double angleDelta) {
    wheel(x, y, pixelDelta != 0 ? pixelDelta : angleDelta / 8, pixelDelta != 0);
}
void Engine::adjustPlayer(QString control, double x, double width) {
    if (width <= 0 || (control != "seek" && control != "volume")) {
        return;
    }
    action("player:" + control + "-fraction:" + QString::number(std::clamp(x / width, 0., 1.), 'g', 16));
}
void Engine::query(QString value) {
    app->hud.setQuery(value);
    wake();
}
void Engine::key(QString value, bool command) {
    app->hud.key(value, command);
    wake();
}
void Engine::pointer(QString type, double x, double y) {
    if (type == "pointermove") {
        if (m_pointerX == x && m_pointerY == y && !m_pointerPending) {
            return;
        }
        m_pointerX = x;
        m_pointerY = y;
        m_pointerPending = true;
    } else {
        flushPointer();
        app->pointer(type, x, y);
        if (type == "pointerdown") {
            m_pressed = true;
        }
        if (type == "pointerup" || type == "pointercancel" || type == "pointerleave") {
            m_pressed = false;
        }
    }
    wake();
}
void Engine::wheel(double x, double y, double delta, bool pixels) {
    if (!std::isfinite(delta) || delta == 0) {
        return;
    }
    m_wheelX = x;
    m_wheelY = y;
    m_wheelDelta += delta;
    m_wheelSteps += pixels ? -delta / 15. : (delta < 0 ? 1 : -1);
    // 单独保留连续舞台位移，避免触控板不足一行的输入被整数行索引吞掉。
    m_wheelDistance += pixels ? -delta / (m_height / 1080.) : -delta / 120. * 65;
    m_wheelPending = true;
    wake();
}
/**
 * 按顺序同步场景、音乐和 HUD 帧数据，保持绘制与命中区域一致。
 */
void Engine::step(double time) {
    if (!ready()) {
        return;
    }
    QElapsedTimer frameTimer;
    if (scene.isProfiling()) {
        frameTimer.start();
        // 复用睡眠场景的帧不能沿用上次模拟耗时，否则现场日志会误报瓶颈。
        scene.timings = {};
    }
    ++m_steps;
    const bool reuse = m_sceneSleeping && !scene.changed();
    const auto object = app->step(time, m_width / (m_height / 1080), reuse);
    if (object.isEmpty()) {
        return;
    }
    m_frame = scene.frame;
    auto signature = m_frame;
    for (const auto &key : {"time", "stats", "labels", "boot", "pointerCursor"}) {
        signature.remove(key);
    }
    bool stable =
        equivalent(signature, m_sceneSignature) && m_previousBuffers.size() == scene.drawBuffers.size();
    for (auto it = scene.drawBuffers.begin(); stable && it != scene.drawBuffers.end(); ++it) {
        const auto old = m_previousBuffers.value(it.key());
        stable = equivalent(it->matrices, old.matrices) && equivalent(it->themes, old.themes);
    }
    m_stableFrames = stable ? m_stableFrames + 1 : 0;
    if (!stable || scene.changed()) {
        m_sceneSleeping = false;
    }
    m_sceneSignature = signature;
    m_previousBuffers = scene.drawBuffers;
    if (m_stableFrames >= 4 && !scene.changed() && m_frame["mode"] != "boot" &&
        !m_frame["pendingAnimations"].toBool()) {
        m_sceneSleeping = true;
    }
    const auto current = object["current"].toObject();
    const auto cover = object["cover"].toString();
    const auto coverRevision = host.image(cover).cacheKey();
    const bool visualChanged =
        !stable || current != m_current || cover != m_cover || coverRevision != m_coverRevision;
    m_coverRevision = coverRevision;
    m_current = current;
    m_cover = object["cover"].toString();
    // 图形设备在后台可销毁；仅保存当前与可见归位卡片的图片，供恢复时重建纹理。
    const auto musicKey = current["key"].toString("empty");
    m_musicTextures[musicKey] = {current, host.image(m_cover)};
    QSet<QString> retainedKeys{musicKey};
    for (const auto &key : m_frame["returningMusicKeys"].toArray()) {
        retainedKeys.insert(key.toString());
    }
    for (const auto &value : m_frame["draws"].toArray()) {
        const auto key = value.toObject()["musicKey"].toString();
        if (!key.isEmpty()) {
            retainedKeys.insert(key);
        }
    }
    for (auto it = m_musicTextures.begin(); it != m_musicTextures.end();) {
        if (!retainedKeys.contains(it.key())) {
            it = m_musicTextures.erase(it);
        } else {
            ++it;
        }
    }
    auto commands = object["commands"].toArray();
    if (commands != m_commands) {
        m_commands = commands;
        ++m_hudUpdates;
        emit hudUpdated();
    }
    if (visualChanged) {
        ++m_sceneUpdates;
        emit sceneUpdated();
    }
    auto state = object["state"].toObject().toVariantMap();
    if (state != m_state) {
        m_state = state;
        const auto loginMethod = m_state.value("loginMethod").toString();
        if (loginMethod != m_loginMethod) {
            m_loginMethod = loginMethod;
            emit clearCredentials();
        }
        emit stateChanged();
    }
    auto hits = object["hits"].toArray().toVariantList();
    if (hits != m_hits) {
        m_hits = hits;
        emit hitsChanged();
    }
    if (scene.isProfiling()) {
        scene.timings.engineMs = frameTimer.nsecsElapsed() / 1000000.;
    }
    emit updated();
}
void Engine::snapshot(QString path) {
    if (m_frame.isEmpty()) {
        return;
    }
    QDir().mkpath(path);
    const QSize size(1920, 1080);
    auto metal = renderReference(root(), m_frame, m_current, cover(), size, scene.drawBuffers);
    saveImageNative(metal, path + "/qt-metal.png");
    QImage hud(size, QImage::Format_RGBA8888_Premultiplied);
    hud.fill(Qt::transparent);
    QPainter hudPainter(&hud);
    m_glyphs.commands(hudPainter, m_commands, [this](QString key) { return host.image(key); });
    hudPainter.end();
    saveImageNative(hud, path + "/qt-panel.png");
    QPainter painter(&metal);
    painter.drawImage(0, 0, hud);
    painter.end();
    metal.save(path + "/qt-composite.png");
    QFile file(path + "/qt-state.json");
    if (file.open(QIODevice::WriteOnly)) {
        file.write(QJsonDocument(m_frame).toJson());
    }
}
/** 独立包离线验收直接检查原生状态、原始模型与实际 QRhi 输出，不创建脚本引擎。 */
int Engine::selfTest() {
    bool ok =
        ready() && DiscGeometry::validate() && runNativeHostChecks(root()) && runNativeMusicChecks(root());
    scene.review("archive");
    step(2.101);
    ok &= !m_frame["draws"].toArray().isEmpty() && m_frame["stats"].toObject()["archiveCount"].toInt() > 0;
    QFile fixture(root() + "/scene-fixture.json");
    if (!fixture.open(QIODevice::ReadOnly)) {
        qCritical() << "Missing offline scene fixture";
        return 1;
    }
    const auto expected = QJsonDocument::fromJson(fixture.readAll()).object();
    const auto legacy = expected["frame"].toObject();
    ok &= equivalent(m_frame["view"], legacy["view"]) &&
          equivalent(m_frame["projection"], legacy["projection"]);
    for (const auto &entry : expected["rays"].toArray()) {
        const auto ray = entry.toObject();
        const auto hit = scene.pick(ray["x"].toDouble(), ray["y"].toDouble());
        const auto cell = ray["hit"].toObject();
        if (cell.isEmpty()) {
            ok &= !hit;
        } else {
            ok &= hit && hit->lane == cell["lane"].toInt() && hit->row == cell["row"].toInt();
        }
    }
    if (qEnvironmentVariableIntValue("RHINE_GPU_TEST") == 1) {
        const QSize size(960, 540);
        const auto actual =
            renderReference(root(), m_frame, m_current, host.image(m_cover), size, scene.drawBuffers);
        const auto original = renderReference(root(), legacy, m_current, host.image(m_cover), size);
        ok &= runGpuReferenceCheck(original, actual);
        if (!ok) {
            qCritical() << "Native GPU frame differs from original fixture";
        }
    }
    qInfo() << "Qt native scene, Host, music, playback and offline package checks:"
            << (ok ? "passed" : "FAILED");
    return ok ? 0 : 1;
}

int Engine::renderFixtures(QString source, QString output) {
    for (const auto &name : QDir(source).entryList({"*.json"}, QDir::Files, QDir::Name)) {
        QFile input(source + "/" + name);
        if (!input.open(QIODevice::ReadOnly)) {
            return 1;
        }
        const auto fixture = QJsonDocument::fromJson(input.readAll()).object();
        const auto store = fixture["store"].toObject();
        const auto settings = fixture["hud"].toObject();
        app->music.current = store["current"].toObject();
        const auto lists = store["lists"].toArray();
        const auto totals = store["totals"].toArray();
        const auto more = store["hasMore"].toArray();
        for (int lane = 0; lane < 5; ++lane) {
            app->music.lists[lane] = lists.at(lane).toArray();
            app->music.totals[lane] = totals.at(lane).toInt();
            app->music.hasMore[lane] = more.at(lane).toBool();
        }
        app->music.keyword = store["keyword"].toString();
        app->music.status = store["status"].toString();
        app->hud.modal = settings["modal"].toString();
        app->hud.dark = settings["dark"].toBool();
        app->hud.themeMode = settings["themeMode"].toString();
        app->hud.reduced = settings["reduced"].toBool();
        app->hud.motion.set(true, 0, true);
        m_frame = fixture["frame"].toObject();
        app->hud.draw(m_frame, 1920, 50);
        m_commands = app->hud.commands;
        m_current = app->music.current;
        m_cover.clear();
        const auto folder = output + "/" + fixture["name"].toString();
        snapshot(folder);
        QFile hitsFile(folder + "/qt-hits.json");
        if (hitsFile.open(QIODevice::WriteOnly)) {
            hitsFile.write(QJsonDocument(app->hud.hits).toJson());
        }
    }
    return failure.isEmpty() ? 0 : 1;
}
