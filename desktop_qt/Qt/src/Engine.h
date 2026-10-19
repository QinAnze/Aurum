#pragma once
#include "Glyphs.h"
#include "Host.h"
#include "NativeApplication.h"
#include <QElapsedTimer>
#include <QVariantMap>
#include <QQuickWindow>
#include <QPointer>
#include <atomic>
class Engine : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantMap state READ state NOTIFY stateChanged)
    Q_PROPERTY(QVariantList hits READ hits NOTIFY hitsChanged)
    Q_PROPERTY(QVariantMap performance READ performance NOTIFY stateChanged)
  public:
    Engine(QString root, bool offline = false, QObject *parent = nullptr);
    ~Engine() override;
    QVariantMap state() const {
        return m_state;
    }
    QVariantList hits() const {
        return m_hits;
    }
    QJsonObject frame() const {
        return m_frame;
    }
    QJsonObject current() const {
        return m_current;
    }
    QImage cover() const {
        return host.image(m_cover);
    }
    QJsonArray commands() const {
        return m_commands;
    }
    Glyphs *glyphs() {
        return &m_glyphs;
    }
    QString root() const {
        return host.root;
    }
    Q_INVOKABLE void resize(double width, double height);
    Q_INVOKABLE void action(QString action);
    Q_INVOKABLE void submitForm(QString account, QString password);
    Q_INVOKABLE bool keyEvent(int key, int modifiers, QString text);
    Q_INVOKABLE void searchAccepted(QString text, int modifiers);
    Q_INVOKABLE void wheelInput(double x, double y, double pixelDelta, double angleDelta);
    Q_INVOKABLE void adjustPlayer(QString control, double x, double width);
    Q_INVOKABLE void toggleFullscreen();
    void setWindow(QQuickWindow *window);
    Q_INVOKABLE void query(QString query);
    Q_INVOKABLE void key(QString key, bool command);
    Q_INVOKABLE void pointer(QString type, double x, double y);
    Q_INVOKABLE void wheel(double x, double y, double delta, bool pixels = false);
    Q_INVOKABLE void snapshot(QString path);
    void step(double time);
    QVariantMap performance() const;
    SceneDrawBuffers drawBuffers() const {
        return scene.drawBuffers;
    }
    struct MusicTexture {
        QJsonObject item;
        QImage cover;
    };
    using MusicTextures = QHash<QString, MusicTexture>;
    MusicTextures musicTextures() const {
        return m_musicTextures;
    }
    void trimMemory();
    void recordResourceRelease() {
        m_gpuResources.store(0, std::memory_order_relaxed);
        m_musicTextureBytes.store(0, std::memory_order_relaxed);
    }
    Q_INVOKABLE void setVisible(bool value);
    void wake(bool input = true);
    void start();
    void recordRender(quint64 resources, quint64 bindings = 0, quint64 textureBytes = 0,
                      quint64 coverUploads = 0, quint64 drawCalls = 0) {
        m_renderFrames.fetch_add(1, std::memory_order_relaxed);
        m_gpuResources.store(resources, std::memory_order_relaxed);
        m_bindingCreations.fetch_add(bindings, std::memory_order_relaxed);
        m_musicTextureBytes.store(textureBytes, std::memory_order_relaxed);
        m_coverUploads.fetch_add(coverUploads, std::memory_order_relaxed);
        m_lastDrawCalls.store(drawCalls, std::memory_order_relaxed);
    }
    bool ready() const;
    int selfTest();
    int renderFixtures(QString source, QString output);
    Host host;
    NativeScene scene;
    std::unique_ptr<NativeApplication> app;
    QString failure;
  signals:
    void updated();
    void sceneUpdated();
    void hudUpdated();
    void stateChanged();
    void hitsChanged();
    void clearCredentials();

  protected:
    bool eventFilter(QObject *watched, QEvent *event) override;

  private:
    std::atomic<quint64> m_renderFrames{0}, m_gpuResources{0};
    std::atomic<quint64> m_bindingCreations{0};
    std::atomic<quint64> m_musicTextureBytes{0};
    std::atomic<quint64> m_coverUploads{0};
    std::atomic<quint64> m_lastDrawCalls{0};
    MusicTextures m_musicTextures;
    Glyphs m_glyphs;
    QTimer timer, mediaTimer;
    bool m_started = false;
    bool m_visible = true;
    bool m_sleeping = false;
    bool m_sceneSleeping = false;
    bool m_pointerPending = false;
    bool m_pressed = false;
    bool m_wheelPending = false;
    double m_pointerX = 0;
    double m_pointerY = 0;
    double m_wheelX = 0;
    double m_wheelY = 0;
    double m_wheelDelta = 0;
    double m_wheelSteps = 0;
    double m_wheelDistance = 0;
    qint64 m_lastTick = 0, m_lastInput = 0;
    double m_animationTime = 0;
    quint64 m_steps = 0, m_sceneUpdates = 0, m_hudUpdates = 0;
    int m_stableFrames = 0;
    QJsonObject m_sceneSignature;
    SceneDrawBuffers m_previousBuffers;
    void tick();
    void flushPointer();
    void pollMedia();
    QElapsedTimer clock;
    double m_width = 1280;
    double m_height = 720;
    QVariantMap m_state;
    QVariantList m_hits;
    QJsonObject m_frame, m_current;
    QJsonArray m_commands;
    QPointer<QQuickWindow> m_window;
    QWindow::Visibility m_windowedVisibility = QWindow::Windowed;
    QString m_loginMethod;
    QString m_cover;
    qint64 m_coverRevision = 0;
};
