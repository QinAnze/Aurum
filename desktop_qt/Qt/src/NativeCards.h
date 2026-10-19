#pragma once
#include "SceneTypes.h"
#include <QJsonObject>
#include <QJsonArray>

// 卡片共用静态部件模板；每个活动根只携带矩阵与外观状态。
class NativeCards {
  public:
    QString expand(QJsonObject &frame, const QByteArray &bytes, SceneDrawBuffers &buffers);

  private:
    QJsonArray parts;
};
