#include "Hud.h"
#include "Engine.h"
#include <QPainter>
Hud::Hud(QQuickItem *parent) : QQuickPaintedItem(parent) {
    setOpaquePainting(false);
    setAntialiasing(true);
}
void Hud::setEngine(Engine *engine) {
    if (engine == m_engine) {
        return;
    }
    if (m_engine) {
        disconnect(m_engine, nullptr, this, nullptr);
    }
    m_engine = engine;
    if (engine) {
        connect(engine, &Engine::hudUpdated, this, [this] { update(); });
    }
    emit engineChanged();
    update();
}
void Hud::paint(QPainter *painter) {
    if (!m_engine) {
        return;
    }
    painter->save();
    painter->scale(height() / 1080, height() / 1080);
    m_engine->glyphs()->commands(*painter, m_engine->commands(),
                                 [this](QString key) { return m_engine->host.image(key); });
    painter->restore();
}
