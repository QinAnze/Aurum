#pragma once
#include "SceneMath.h"
#include <QJsonObject>
#include <QSet>

class SceneAppearance {
  public:
    explicit SceneAppearance(const QJsonObject &asset);
    QJsonArray actorTemplate;
    QJsonArray instances;
    QVector<int> pickingMeshes;
    SceneMath::Vector boundsCenter{0, 1.85, 0};
    double boundsRadius = 3.3;
    QJsonObject floor(double theme) const;
    static QJsonArray color(QString hex);
    static QJsonArray blend(const QJsonArray &from, const QJsonArray &to, double amount);

  private:
    static QJsonObject material(const QJsonObject &source);
};
