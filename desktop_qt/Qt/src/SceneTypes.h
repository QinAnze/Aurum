#pragma once
#include <QByteArray>
#include <QHash>

struct SceneDrawData {
    QByteArray matrices;
    QByteArray themes;
};
using SceneDrawBuffers = QHash<int, SceneDrawData>;
