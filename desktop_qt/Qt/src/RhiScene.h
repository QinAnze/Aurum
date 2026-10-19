#pragma once
#include "SceneTypes.h"
#include <QImage>
#include <QJsonObject>
#include <QQuickRhiItem>
class Engine;
class RhiScene : public QQuickRhiItem {
    Q_OBJECT
    Q_PROPERTY(Engine *engine READ engine WRITE setEngine NOTIFY engineChanged)
  public:
    explicit RhiScene(QQuickItem *parent = nullptr);
    Engine *engine() const {
        return m_engine;
    }
    void setEngine(Engine *value);
  signals:
    void engineChanged();

  protected:
    QQuickRhiItemRenderer *createRenderer() override;

  private:
    Engine *m_engine = nullptr;
};
QImage renderReference(const QString &root, const QJsonObject &frame, const QJsonObject &item,
                       const QImage &cover, QSize size, const SceneDrawBuffers &buffers = {},
                       quint64 *drawCalls = nullptr);
