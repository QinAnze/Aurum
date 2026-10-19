#pragma once
#include "SceneMotion.h"
#include <QPointF>
#include <QVector>
#include <optional>

namespace SceneMotion {
struct DragPosition {
    double lane = 0;
    double row = 0;
};
struct DragProjection {
    QPointF lane;
    QPointF row;
};

class ArchiveDrag {
  public:
    void start(double x, double y, DragProjection projection, double timeMs = 0);
    void move(double x, double y, double timeMs);
    DragPosition releaseVelocity(double timeMs, bool reduced) const;
    bool active = false;
    bool moved = false;
    DragPosition value;

  private:
    struct Sample {
        DragPosition value;
        double time = 0;
    };
    QPointF m_start;
    QPointF m_pointer;
    QPointF m_motionDirection;
    std::optional<DragProjection> m_inverse;
    QVector<Sample> m_samples;
    double m_lastMotion = -1e100;
};

class ArchiveMomentum {
  public:
    enum class Phase { Coasting, Snapping, Idle };
    ArchiveMomentum(double value, double velocity);
    void step(double seconds, bool coasting);
    Spring motion;
    Phase phase;
    double target;
};

class ArchivePlaneMomentum {
  public:
    ArchivePlaneMomentum(DragPosition value, DragPosition velocity);
    ArchiveMomentum::Phase phase() const;
    DragPosition value() const;
    DragPosition velocity() const;
    void step(double seconds);
    ArchiveMomentum lane;
    ArchiveMomentum row;
};
}
