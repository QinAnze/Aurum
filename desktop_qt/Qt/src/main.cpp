#include "AppIdentity.h"
#include "AppStorage.h"
#include "Engine.h"
#include "FrameProfiler.h"
#include "Hud.h"
#include "RhiScene.h"
#include <QDir>
#include <QFileInfo>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QIcon>
#include <QLoggingCategory>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickGraphicsConfiguration>
#include <QQuickWindow>
#include <QTimer>
#include <cstdio>
#include <cstring>
int makeIcon(const QString &directory);
int runUiChecks(Engine &backend, QQuickWindow *window, const QString &output);
/**
 * 建立应用身份、Qt 引擎和原生窗口。
 * 离线测试与正式播放沿用同一入口，资源只从独立应用读取。
 */
int main(int argc, char **argv) {
#ifdef Q_OS_WIN
    const auto storageError = AppStorage::initializePortable(AppStorage::executableDirectory());
    if (!storageError.isEmpty()) {
        std::fprintf(stderr, "%s\n", storageError.toUtf8().constData());
        return 1;
    }
#endif
    // 两个平台都明确使用 FFmpeg，设备切换和重连由播放器独立处理。
    // 必须在 Qt 初始化多媒体前选择后端，显式环境变量仍可用于兼容性对照。
    if (qEnvironmentVariableIsEmpty("QT_MEDIA_BACKEND")) {
        qputenv("QT_MEDIA_BACKEND", "ffmpeg");
    }
    // Windows GUI 子系统默认可能将 Qt 日志送到调试器；测试必须写入 CTest 的标准错误管道。
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--self-test") == 0 || std::strcmp(argv[i], "--ui-self-test") == 0) {
            qInstallMessageHandler(
                [](QtMsgType type, const QMessageLogContext &context, const QString &message) {
                    const auto text = qFormatLogMessage(type, context, message).toUtf8();
                    std::fprintf(stderr, "%s\n", text.constData());
                    std::fflush(stderr);
                });
            break;
        }
    }
    QLoggingCategory::setFilterRules("qt.qml.usedbeforedeclared=false");
#ifdef Q_OS_MACOS
    // Qt 需在创建 QGuiApplication 前找到包内平台插件；某些 kit 会忽略资源目录里的 qt.conf。
    const QDir bundledPlugins(QFileInfo(QString::fromLocal8Bit(argv[0])).absolutePath() + "/../PlugIns");
    if (bundledPlugins.exists("platforms/libqcocoa.dylib")) {
        qputenv("QT_PLUGIN_PATH", bundledPlugins.absolutePath().toUtf8());
    }
#endif
    QGuiApplication application(argc, argv);
    application.setWindowIcon(QIcon(":/icons/icon-256.png"));
    QCoreApplication::setOrganizationName(AppIdentity::Organization);
    QCoreApplication::setOrganizationDomain(AppIdentity::Id);
    QCoreApplication::setApplicationName(AppIdentity::Id);
    QGuiApplication::setApplicationDisplayName(AppIdentity::DisplayName);
    const auto args = application.arguments();
    if (args.contains("--make-icon")) {
        return makeIcon(args.value(args.indexOf("--make-icon") + 1));
    }
    QString root = qEnvironmentVariable("RHINE_RESOURCES");
    if (root.isEmpty()) {
        auto bundled = QCoreApplication::applicationDirPath() +
#ifdef Q_OS_MACOS
                       "/../Resources";
#else
                       "/resources";
#endif
        root = QFileInfo(bundled + "/slots.json").exists() ? QDir(bundled).absolutePath()
                                                           : QDir::currentPath() + "/output/resources";
    }
    const bool test = args.contains("--self-test");
    const bool visual = args.contains("--visual-fixtures");
    const bool offline = test || visual || args.contains("--ui-self-test") || args.contains("--offline") ||
                         qEnvironmentVariableIntValue("RHINE_OFFLINE") == 1;
    Engine backend(root, offline);
    if (test) {
        return backend.selfTest();
    }
    if (visual) {
        const int i = args.indexOf("--visual-fixtures");
        return backend.renderFixtures(args.value(i + 1), args.value(i + 2));
    }
    backend.start();
    qmlRegisterType<RhiScene>("Rhine.Native", 1, 0, "RhiScene");
    qmlRegisterType<Hud>("Rhine.Native", 1, 0, "Hud");
    qmlRegisterUncreatableType<Engine>("Rhine.Native", 1, 0, "Engine", "Provided by application");
    QQmlApplicationEngine engine;
#ifdef Q_OS_WIN
    // 创建窗口时先保持隐藏，配置管线缓存后再显示，避免首次渲染写到系统缓存。
    engine.setInitialProperties({{"visible", false}});
#endif
    const auto fontId = QFontDatabase::addApplicationFont(root + "/RhineMiSans-regular.otf");
    const auto families = QFontDatabase::applicationFontFamilies(fontId);
    engine.rootContext()->setContextProperty("rhineFontFamily",
                                             families.isEmpty() ? QString("sans-serif") : families.first());
    engine.rootContext()->setContextProperty("rhine", &backend);
    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &application,
        [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.loadFromModule("RhineMusic", "Main");
    if (engine.rootObjects().isEmpty()) {
        return 1;
    }
    auto window = qobject_cast<QQuickWindow *>(engine.rootObjects().first());
#ifdef Q_OS_WIN
    QQuickGraphicsConfiguration graphics;
    graphics.setAutomaticPipelineCache(false);
    const auto pipelineCache = AppStorage::cacheDirectory() + "/shaders/pipeline.cache";
    if (QFileInfo::exists(pipelineCache)) {
        graphics.setPipelineCacheLoadFile(pipelineCache);
    }
    graphics.setPipelineCacheSaveFile(pipelineCache);
    window->setGraphicsConfiguration(graphics);
    window->show();
#endif
    backend.setWindow(window);
    window->installEventFilter(&backend);
    if (args.contains("--frame-profile")) {
        const auto path = args.value(args.indexOf("--frame-profile") + 1);
        if (path.isEmpty() || path.startsWith("--")) {
            qWarning() << "--frame-profile requires an output CSV path";
            return 1;
        }
        new FrameProfiler(&backend, window, path);
    }
    // 短暂切换窗口继续复用 GPU；隐藏或最小化超过两秒才释放图形设备和可重建缓存。
    auto backgroundRelease = new QTimer(window);
    backgroundRelease->setSingleShot(true);
    backgroundRelease->setInterval(2000);
    QObject::connect(backgroundRelease, &QTimer::timeout, window, [&backend, window] {
        if (window->isVisible() && window->visibility() != QWindow::Minimized) {
            return;
        }
        backend.trimMemory();
        window->setPersistentSceneGraph(false);
        window->setPersistentGraphics(false);
        window->releaseResources();
    });
    QObject::connect(window, &QWindow::visibilityChanged, window,
                     [window, backgroundRelease](QWindow::Visibility visibility) {
                         if (visibility == QWindow::Hidden || visibility == QWindow::Minimized) {
                             backgroundRelease->start();
                         } else {
                             backgroundRelease->stop();
                             window->setPersistentSceneGraph(true);
                             window->setPersistentGraphics(true);
                         }
                     });
    QObject::connect(
        window, &QQuickWindow::sceneGraphInvalidated, &backend,
        [&backend] { backend.recordResourceRelease(); }, Qt::DirectConnection);
    if (args.contains("--ui-self-test")) {
        return runUiChecks(backend, qobject_cast<QQuickWindow *>(engine.rootObjects().first()),
                           args.value(args.indexOf("--ui-self-test") + 1));
    }
    if (args.contains("--capture")) {
        const auto index = args.indexOf("--capture");
        const auto path = args.value(index + 1);
        if (path.isEmpty()) {
            return 1;
        }
        auto poll = new QTimer(&backend);
        poll->setInterval(200);
        bool *reviewed = new bool(false);
        QObject::connect(poll, &QTimer::timeout, &backend, [&, path, poll, reviewed] {
            if (!backend.ready()) {
                return;
            }
            if (!*reviewed) {
                *reviewed = true;
                backend.scene.review("archive");
                return;
            }
            backend.step(50);
            if (backend.frame().isEmpty()) {
                return;
            }
            poll->stop();
            delete reviewed;
            backend.snapshot(path);
            auto window = qobject_cast<QQuickWindow *>(engine.rootObjects().first());
            if (window) {
                window->grabWindow().save(path + "/qt-window.png");
            }
            application.quit();
        });
        poll->start();
    }
    return application.exec();
}
