#include "SceneDrag.h"
#include <algorithm>
#include <cmath>

namespace SceneMotion {
void ArchiveDrag::start(double x, double y, DragProjection projection, double timeMs) {
    active = false;
    moved = false;
    m_start = {x, y};
    value = {};
    m_samples = {{value, timeMs}};
    m_lastMotion = -1e100;
    m_motionDirection = {};
    m_pointer = {x, y};
    const auto &lane = projection.lane;
    const auto &row = projection.row;
    const auto determinant = lane.x() * row.y() - row.x() * lane.y();
    const auto area = std::hypot(lane.x(), lane.y()) * std::hypot(row.x(), row.y());
    m_inverse.reset();
    if (std::isfinite(area) && area > 0 && std::abs(determinant) > area * 0.001) {
        m_inverse = DragProjection{{row.y() / determinant, -row.x() / determinant},
                                   {-lane.y() / determinant, lane.x() / determinant}};
    }
}

/** 同时逆投影两条轨道；反向移动重新估计释放速度，保留原始毫秒采样窗口。 */
void ArchiveDrag::move(double x, double y, double timeMs) {
    const auto dx = x - m_start.x();
    const auto dy = y - m_start.y();
    const auto distance = std::hypot(dx, dy);
    if (distance > 7) {
        moved = true;
    }
    if (!m_inverse || (!active && distance < 10)) {
        return;
    }
    active = true;
    const DragPosition next{dx * m_inverse->lane.x() + dy * m_inverse->lane.y(),
                            dx * m_inverse->row.x() + dy * m_inverse->row.y()};
    if (!m_samples.isEmpty()) {
        const auto previous = m_samples.constLast();
        const QPointF delta(x - m_pointer.x(), y - m_pointer.y());
        if (std::hypot(delta.x(), delta.y()) > 1e-9) {
            m_lastMotion = timeMs;
            if (QPointF::dotProduct(delta, m_motionDirection) < 0) {
                m_samples = {previous};
            }
            m_motionDirection = delta;
        }
    }
    m_pointer = {x, y};
    value = next;
    if (!m_samples.isEmpty() && m_samples.constLast().time == timeMs) {
        m_samples.last() = {next, timeMs};
    } else {
        m_samples.append({next, timeMs});
    }
    m_samples.removeIf([timeMs](const Sample &sample) { return timeMs - sample.time > 120; });
    if (m_samples.size() > 32) {
        m_samples.remove(0, m_samples.size() - 32);
    }
}

DragPosition ArchiveDrag::releaseVelocity(double timeMs, bool reduced) const {
    if (reduced || m_samples.isEmpty() || timeMs - m_lastMotion > 80) {
        return {};
    }
    const auto &first = m_samples.constFirst();
    const auto &last = m_samples.constLast();
    if (last.time - first.time < 8) {
        return {};
    }
    const auto scale = 1000 / (last.time - first.time);
    return {(last.value.lane - first.value.lane) * scale, (last.value.row - first.value.row) * scale};
}

ArchiveMomentum::ArchiveMomentum(double value, double velocity)
    : motion{value, velocity}, phase(std::abs(velocity) >= 0.75 ? Phase::Coasting : Phase::Snapping),
      target(std::floor(value + 0.5)) {
}

void ArchiveMomentum::step(double seconds, bool coasting) {
    constexpr double friction = 2.4;
    if (coasting) {
        const auto decay = std::exp(-friction * seconds);
        motion.value += motion.velocity * (1 - decay) / friction;
        motion.velocity *= decay;
        if (std::abs(motion.velocity) < 0.6) {
            target = std::floor(motion.value + motion.velocity / friction + 0.5);
            phase = Phase::Snapping;
        }
    } else if (phase == Phase::Snapping) {
        motion.damp(target, 10, seconds);
        if (std::abs(motion.value - target) < 0.0001 && std::abs(motion.velocity) < 0.005) {
            motion.value = target;
            motion.velocity = 0;
            phase = Phase::Idle;
        }
    }
}
ArchivePlaneMomentum::ArchivePlaneMomentum(DragPosition value, DragPosition velocity)
    : lane(value.lane, velocity.lane), row(value.row, velocity.row) {
}
ArchiveMomentum::Phase ArchivePlaneMomentum::phase() const {
    using Phase = ArchiveMomentum::Phase;
    if (lane.phase == Phase::Coasting || row.phase == Phase::Coasting) {
        return Phase::Coasting;
    }
    if (lane.phase == Phase::Idle && row.phase == Phase::Idle) {
        return Phase::Idle;
    }
    return Phase::Snapping;
}
DragPosition ArchivePlaneMomentum::value() const {
    return {lane.motion.value, row.motion.value};
}
DragPosition ArchivePlaneMomentum::velocity() const {
    return {lane.motion.velocity, row.motion.velocity};
}
void ArchivePlaneMomentum::step(double seconds) {
    const bool coasting = phase() == ArchiveMomentum::Phase::Coasting;
    lane.step(seconds, coasting);
    row.step(seconds, coasting);
}
}
