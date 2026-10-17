#pragma once
#include <QByteArray>
#include <vector>

// 原外壳局部坐标为 [-2.5, 2.5] × [0, 3.7]，不改变外壳、相机或动画。
namespace DiscGeometry {
constexpr float CenterX = 0.f;
constexpr float CenterY = 1.85f;
constexpr float Radius = 1.57f;
constexpr float PrintRadius = 1.51f;
constexpr float HubRadius = .23f;
constexpr float HoleRadius = .085f;
constexpr int Segments = 192;

struct Mesh {
    std::vector<float> vertices;
    int count() const {
        return int(vertices.size() / 12);
    }
    QByteArray bytes() const;
};
Mesh annulus(float inner, float outer, float front, float back, bool solid = true);
bool validate();
}
