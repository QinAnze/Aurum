#include "FrameProfiler.h"
#include "Engine.h"
#include <QDateTime>
#include <QJsonArray>
#include <QQuickWindow>

/**
 * 记录 GUI 帧准备、渲染线程同步与提交成本，以及最近一次呈现间隔。
 * 只有 --frame-profile 指定文件时启用，日志不包含账号、曲目或请求内容。
 */
FrameProfiler::FrameProfiler(Engine *engine, QQuickWindow *window, const QString &path)
    : QObject(window), file(path), stream(&file) {
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
        qWarning() << "Cannot open frame profile:" << file.errorString();
        return;
    }
    clock.start();
    epochMs = QDateTime::currentMSecsSinceEpoch();
    stream << "timestamp_ms,step_cpu_ms,scene_native_ms,scene_metadata_ms,scene_buffers_ms,"
              "latest_present_gap_ms,latest_sync_cpu_ms,latest_submit_cpu_ms,presents,draws,"
              "returning_cards,culled_cards,shadow_only_cards,latest_gpu_draw_calls\n";
    engine->scene.profileFrames(true);
    connect(
        window, &QQuickWindow::beforeSynchronizing, this, [this] { syncTimer.start(); },
        Qt::DirectConnection);
    connect(
        window, &QQuickWindow::afterSynchronizing, this,
        [this] { syncNs.store(syncTimer.nsecsElapsed(), std::memory_order_relaxed); }, Qt::DirectConnection);
    connect(
        window, &QQuickWindow::beforeRendering, this, [this] { renderTimer.start(); }, Qt::DirectConnection);
    connect(
        window, &QQuickWindow::afterRendering, this,
        [this] { submitNs.store(renderTimer.nsecsElapsed(), std::memory_order_relaxed); },
        Qt::DirectConnection);
    connect(
        window, &QQuickWindow::frameSwapped, this,
        [this] {
            const auto now = clock.nsecsElapsed();
            const auto previous = presentNs.exchange(now, std::memory_order_relaxed);
            presentGapNs.store(previous ? now - previous : 0, std::memory_order_relaxed);
            presents.fetch_add(1, std::memory_order_relaxed);
        },
        Qt::DirectConnection);
    // GUI 和渲染线程的采样不同步；明确记录最近一次呈现数据，不把它当作本帧 GPU 耗时。
    connect(engine, &Engine::updated, this, [this, engine] {
        const auto &timings = engine->scene.timings;
        const auto frame = engine->frame();
        stream << epochMs + clock.elapsed() << ',' << timings.engineMs << ',' << timings.simulateMs << ','
               << timings.metadataMs << ',' << timings.buffersMs << ','
               << presentGapNs.load(std::memory_order_relaxed) / 1000000. << ','
               << syncNs.load(std::memory_order_relaxed) / 1000000. << ','
               << submitNs.load(std::memory_order_relaxed) / 1000000. << ','
               << presents.load(std::memory_order_relaxed) << ',' << frame["draws"].toArray().size() << ','
               << frame["returningCards"].toInt() << ',' << frame["culledCards"].toInt() << ','
               << frame["shadowCards"].toInt() << ','
               << engine->performance().value("gpuDrawCalls").toULongLong() << '\n';
    });
    qInfo() << "Frame profiling enabled:" << path;
}

FrameProfiler::~FrameProfiler() {
    if (file.isOpen()) {
        stream.flush();
    }
}
