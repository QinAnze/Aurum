#include "NativePicking.h"
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <limits>
#include <numeric>
#include <vector>

namespace {
using Vector = std::array<double, 3>;
Vector subtract(const Vector &first, const Vector &second) {
    return {first[0] - second[0], first[1] - second[1], first[2] - second[2]};
}
Vector cross(const Vector &first, const Vector &second) {
    return {first[1] * second[2] - first[2] * second[1], first[2] * second[0] - first[0] * second[2],
            first[0] * second[1] - first[1] * second[0]};
}
double dot(const Vector &first, const Vector &second) {
    return first[0] * second[0] + first[1] * second[1] + first[2] * second[2];
}
struct Box {
    Vector low{INFINITY, INFINITY, INFINITY};
    Vector high{-INFINITY, -INFINITY, -INFINITY};
    void include(const Vector &point) {
        for (int axis = 0; axis < 3; ++axis) {
            low[axis] = std::min(low[axis], point[axis]);
            high[axis] = std::max(high[axis], point[axis]);
        }
    }
    void include(const Box &box) {
        include(box.low);
        include(box.high);
    }
    bool intersects(const Vector &origin, const Vector &direction, double best) const {
        double near = 0;
        double far = best;
        for (int axis = 0; axis < 3; ++axis) {
            if (direction[axis] == 0) {
                if (origin[axis] < low[axis] || origin[axis] > high[axis]) {
                    return false;
                }
                continue;
            }
            double first = (low[axis] - origin[axis]) / direction[axis];
            double last = (high[axis] - origin[axis]) / direction[axis];
            if (first > last) {
                std::swap(first, last);
            }
            near = std::max(near, first);
            far = std::min(far, last);
            if (near > far) {
                return false;
            }
        }
        return true;
    }
};
struct Node {
    Box box;
    int left = -1;
    int right = -1;
    int first = 0;
    int count = 0;
};
struct Mesh {
    std::vector<Vector> positions;
    std::vector<int> indices;
    std::vector<int> triangles;
    std::vector<Node> nodes;
    int build(const std::vector<Box> &boxes, int first, int count) {
        const int index = int(nodes.size());
        nodes.emplace_back();
        Box box;
        for (int i = first; i < first + count; ++i) {
            box.include(boxes[triangles[i]]);
        }
        nodes[index].box = box;
        if (count <= 8) {
            nodes[index].first = first;
            nodes[index].count = count;
            return index;
        }
        int axis = 0;
        for (int candidate = 1; candidate < 3; ++candidate) {
            if (box.high[candidate] - box.low[candidate] > box.high[axis] - box.low[axis]) {
                axis = candidate;
            }
        }
        const int middle = first + count / 2;
        std::nth_element(triangles.begin() + first, triangles.begin() + middle,
                         triangles.begin() + first + count, [&](int left, int right) {
                             return boxes[left].low[axis] + boxes[left].high[axis] <
                                    boxes[right].low[axis] + boxes[right].high[axis];
                         });
        const int left = build(boxes, first, middle - first);
        const int right = build(boxes, middle, first + count - middle);
        nodes[index].left = left;
        nodes[index].right = right;
        return index;
    }
    void load(const QJsonObject &part, const QByteArray &vertices, const QByteArray &indexBytes) {
        const auto vertexStart = part["vertexStart"].toInt(-1);
        const auto vertexCount = part["vertexCount"].toInt();
        const auto firstIndex = part["start"].toInt(-1);
        const auto indexCount = part["count"].toInt();
        if (vertexStart < 0 || firstIndex < 0 || vertexCount <= 0 || indexCount < 0 ||
            (qint64(vertexStart) + vertexCount) * 48 > vertices.size() ||
            (qint64(firstIndex) + indexCount) * 4 > indexBytes.size()) {
            return;
        }
        positions.reserve(vertexCount);
        for (int index = 0; index < vertexCount; ++index) {
            float point[3];
            std::memcpy(point, vertices.constData() + (vertexStart + index) * 48, sizeof(point));
            positions.push_back({point[0], point[1], point[2]});
        }
        indices.reserve(indexCount);
        for (int index = 0; index < indexCount; ++index) {
            quint32 value;
            std::memcpy(&value, indexBytes.constData() + (firstIndex + index) * 4, sizeof(value));
            indices.push_back(int(value) - vertexStart);
        }
        const int count = int(indices.size() / 3);
        triangles.resize(count);
        std::iota(triangles.begin(), triangles.end(), 0);
        std::vector<Box> boxes(count);
        for (int i = 0; i < count; ++i) {
            for (int vertex = 0; vertex < 3; ++vertex) {
                const auto position = indices[i * 3 + vertex];
                if (position < 0 || position >= int(positions.size())) {
                    positions.clear();
                    triangles.clear();
                    return;
                }
                boxes[i].include(positions[position]);
            }
        }
        nodes.reserve(count / 2 + 16);
        if (count) {
            build(boxes, 0, count);
        }
    }
    double triangle(int index, const Vector &origin, const Vector &direction, int side) const {
        Vector first = positions[indices[index * 3]];
        const auto second = positions[indices[index * 3 + 1]];
        Vector third = positions[indices[index * 3 + 2]];
        if (side == 1) {
            std::swap(first, third);
        }
        const auto edge1 = subtract(second, first);
        const auto edge2 = subtract(third, first);
        const auto normal = cross(edge1, edge2);
        auto denominator = dot(direction, normal);
        double sign = 1;
        if (denominator > 0) {
            if (side != 2) {
                return INFINITY;
            }
        } else if (denominator < 0) {
            sign = -1;
            denominator = -denominator;
        } else {
            return INFINITY;
        }
        const auto difference = subtract(origin, first);
        const auto firstWeight = sign * dot(direction, cross(difference, edge2));
        const auto secondWeight = sign * dot(direction, cross(edge1, difference));
        if (firstWeight < 0 || secondWeight < 0 || firstWeight + secondWeight > denominator) {
            return INFINITY;
        }
        const auto numerator = -sign * dot(difference, normal);
        return numerator < 0 ? INFINITY : numerator / denominator;
    }
    void visit(int index, const Vector &origin, const Vector &direction, int side, double &best) const {
        const auto &node = nodes[index];
        if (!node.box.intersects(origin, direction, best)) {
            return;
        }
        if (node.count) {
            for (int i = node.first; i < node.first + node.count; ++i) {
                best = std::min(best, triangle(triangles[i], origin, direction, side));
            }
        } else {
            visit(node.left, origin, direction, side, best);
            visit(node.right, origin, direction, side, best);
        }
    }
};
}

struct NativePicking::Data {
    QString root;
    std::vector<Mesh> meshes;
    bool prepared = false;
};
NativePicking::NativePicking(QString root) : data(std::make_unique<Data>()) {
    data->root = std::move(root);
}
NativePicking::~NativePicking() = default;
void NativePicking::trimMemory() {
    data->meshes.clear();
    data->meshes.shrink_to_fit();
    data->prepared = false;
}
/** 一次构建不可变卡片模型的原生碰撞树；模型资料和账号协议相互独立。 */
void NativePicking::prepare() {
    if (data->prepared) {
        return;
    }
    data->prepared = true;
    QFile file(data->root + "/archive-cassette.json");
    QFile vertices(data->root + "/archive-cassette.bin");
    QFile indices(data->root + "/archive-cassette-indices.bin");
    if (!file.open(QIODevice::ReadOnly) || !vertices.open(QIODevice::ReadOnly) ||
        !indices.open(QIODevice::ReadOnly)) {
        return;
    }
    const auto parts = QJsonDocument::fromJson(file.readAll()).object()["meshes"].toArray();
    const auto vertexBytes = vertices.readAll();
    const auto indexBytes = indices.readAll();
    data->meshes.resize(parts.size());
    for (qsizetype i = 0; i < parts.size(); ++i) {
        data->meshes[i].load(parts[i].toObject(), vertexBytes, indexBytes);
    }
}
QVariantMap NativePicking::raycast(int mesh, const QVariantList &originValues,
                                   const QVariantList &directionValues, int side) {
    prepare();
    if (mesh < 0 || mesh >= int(data->meshes.size()) || originValues.size() != 3 ||
        directionValues.size() != 3 || data->meshes[mesh].nodes.empty()) {
        return {};
    }
    const Vector origin{originValues[0].toDouble(), originValues[1].toDouble(), originValues[2].toDouble()};
    const Vector direction{directionValues[0].toDouble(), directionValues[1].toDouble(),
                           directionValues[2].toDouble()};
    double best = INFINITY;
    data->meshes[mesh].visit(0, origin, direction, side, best);
    if (!std::isfinite(best)) {
        return {};
    }
    return {{"x", origin[0] + direction[0] * best},
            {"y", origin[1] + direction[1] * best},
            {"z", origin[2] + direction[2] * best}};
}
