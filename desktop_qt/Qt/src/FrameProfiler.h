#pragma once
#include <QElapsedTimer>
#include <QFile>
#include <QObject>
#include <QTextStream>
#include <atomic>

class Engine;
class QQuickWindow;

// 仅显式启用诊断时记录
class FrameProfiler : public QObject {
  public:
    FrameProfiler(Engine *engine, QQuickWindow *window, const QString &path);
    ~FrameProfiler() override;

  private:
    QFile file;
    QTextStream stream;
    QElapsedTimer clock;
    QElapsedTimer syncTimer;
    QElapsedTimer renderTimer;
    std::atomic<qint64> syncNs{0};
    std::atomic<qint64> submitNs{0};
    std::atomic<qint64> presentNs{0};
    std::atomic<qint64> presentGapNs{0};
    std::atomic<quint64> presents{0};
    qint64 epochMs = 0;
};
