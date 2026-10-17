#pragma once
#include "Glyphs.h"
#include "MusicLibrary.h"
#include "UiMotion.h"
#include <QCache>
#include <QPointF>
#include <QRectF>
#include <map>
#include <optional>

// 场景边界只传递值和原生回调；界面控制器不持有脚本对象。
struct HudSceneActions {
    std::function<void(QString)> mode;
    std::function<void(bool)> theme;
    std::function<void(bool)> reduced;
    std::function<void(QString, double, double, double)> pointer;
    std::function<void(QString)> viewer;
    std::function<void(QString)> viewerKey;
    std::function<void()> openViewer;
    std::function<void(bool)> coverFront;
};

class NativeHud : public QObject {
  public:
    struct Row {
        int index = -1;
        QJsonObject value;
        QVector<int> indices;
    };
    struct Layout {
        double left = 40;
        double sidebar = 250;
        double x = 326;
        double width = 0;
        double top = 260;
        double rowsY = 434;
        double rowHeight = 54;
        int rowCount = 9;
        double bottom = 956;
    };
    NativeHud(Host *host, Glyphs *glyphs, MusicLibrary *music, HudSceneActions scene,
              QObject *parent = nullptr);
    void draw(QJsonObject frame, double width, double time);
    QJsonObject state() const;
    void action(QString action);
    void key(QString key, bool command);
    void wheel(double x, double y, double delta, std::optional<int> steps = std::nullopt,
               std::optional<double> distance = std::nullopt);
    void form(QJsonObject fields);
    void openModal(QString kind);
    void closeModal();
    void setQuery(QString value);
    void pageResults(int direction);
    bool animating(double time) const;
    QVector<Row> rows(int lane);
    QRectF modalBounds(double width) const;
    Layout containerLayout(double width) const;
    QJsonArray commands;
    QJsonArray hits;
    QJsonObject frame;
    QString tab = "overview";
    QString modal;
    QString query;
    QString formKind;
    QString formPID;
    QString confirmTitle;
    QString groupBy = "none";
    QString activeGroup;
    QString artistTab = "songs";
    QString themeMode;
    int listOffset = 0;
    int musicCollection = 1;
    int trackOffset = 0;
    int bodyOffset = 0;
    int queueOffset = 0;
    bool dark = false;
    bool reduced = false;
    bool closing = false;
    bool lyricsMode = false;
    double width = 1920;
    double lastTime = 0;
    UiMotion::SurfaceMotion motion;
    std::optional<QRectF> playerSeekRect;
    std::optional<QRectF> playerVolumeRect;

  private:
    struct LyricRow {
        double top = 0;
        QStringList text;
        QStringList translation;
    };
    struct Page {
        QString modal;
        int lane;
        quint64 generation;
        int desired;
    };
    Host *m_host;
    Glyphs *m_glyphs;
    MusicLibrary *m_music;
    HudSceneActions m_scene;
    quint64 m_searchGeneration = 0;
    std::optional<Page> m_page;
    std::function<void()> m_confirm;
    QCache<QString, QString> m_fitCache{512};
    std::map<QString, UiMotion::RollingLabel> m_rolling;
    QString m_rowsKey;
    QVector<Row> m_rows;
    QString m_resultSignature;
    double m_resultStart = 0;
    bool m_modalControls = false;
    QJsonObject m_lyricsDocument;
    double m_lyricsWidth = 0;
    QVector<LyricRow> m_lyricsLayout;
    double m_lyricsScroll = 0;
    std::optional<double> m_lyricsBrowse;
    std::optional<double> m_lyricsTarget;
    std::optional<UiMotion::ReelCurve> m_lyricsCurve;
    int m_lyricsPlainOffset = 0;
    void finishPage();
    void musicAction(const QStringList &parts, const QString &action);
    void playerAction(const QStringList &parts);
    QJsonArray ink() const;
    void op(QJsonArray command);
    void save();
    void restore();
    void alpha(double value);
    void translate(double x, double y);
    void scale(double x, double y);
    void clip(double x, double y, double width, double height);
    void fill(double x, double y, double width, double height, QJsonArray color = {});
    void text(QString value, double x, double y, double size, QString weight = "regular", double tracking = 0,
              QJsonArray color = {});
    void aligned(QString value, double x, double y, double size, QString weight = "regular",
                 double tracking = 0);
    QString fit(QString value, double size, double width, QString weight = "regular");
    void limited(QString value, double x, double y, double size, double width, QString weight = "regular");
    void centeredText(QString value, double x, double cy, double size, QString weight = "regular",
                      bool horizontal = false);
    void rollingText(QString key, QString value, double x, double y, double size, QString weight = "regular",
                     double tracking = 0, bool numeric = false);
    void roll(QString key, QString value, double x, double y, double size, double width,
              QString weight = "regular", bool numeric = false);
    void hit(double x, double y, double width, double height, QString action, QString label = {});
    void button(QString label, double x, double y, double width, double height, QString action, double size,
                QString weight = "regular");
    void control(QString label, double x, double y, double width, QString action);
    void rule(double x, double y, double width, double opacity = 0.4);
    void image(QString key, double x, double y, double width, double height);
    void art(QString key, double x, double y, double size, int count = -1, double tracking = 0,
             QJsonArray color = {});
    void brand();
    void brandLine(int index);
    void navigation(double width);
    void footer(double width);
    void empty(double width);
    void archive(double width);
    void actionButton(QString label, double x, double y, double width, QString action, bool primary = false);
    void detail(double width, double opacity);
    void lyricsPanel(double x, double width);
    QString body() const;
    void container(double width, double opacity);
    void viewer(double width);
    std::array<double, 2> rowMotion(const QString &signature, int index);
    void modalDraw(double width);
    void loginPanel(double x, double y, double width);
    void libraryPanel(double x, double y, double width);
    void discoverPanel(double x, double y, double width);
    void playerBar(double x, double y, double width);
    void playerPanel(double x, double y, double width);
    void platformChoices(double x, double y, double width, bool expanded = false);
    void platformPanel(double x, double y, double width);
    void settings(double x, double y, double width);
    void logo(double x, double y, double width);
    void boot(double width);
    void scan(const QJsonObject &boot);
    static QString clock(double ms);
};
