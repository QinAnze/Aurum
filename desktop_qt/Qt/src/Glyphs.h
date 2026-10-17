#pragma once
#include <QCache>
#include <QHash>
#include <QImage>
#include <QJsonArray>
#include <QMutex>
#include <QObject>
#include <QPainter>
#include <QPainterPath>
#include <QRawFont>
#include <QStringList>
#include <QVariantMap>
class Glyphs : public QObject {
    Q_OBJECT
  public:
    explicit Glyphs(const QString &root);
    ~Glyphs() override = default;
    struct Glyph {
        double advance = 1;
        QPainterPath path;
    };
    Q_INVOKABLE double width(QString text, double size, QString weight = "regular", double tracking = 0);
    Q_INVOKABLE QVariantMap bounds(QString text, double size, QString weight = "regular");
    Q_INVOKABLE double inset(QString text, double size, QString weight = "regular");
    Q_INVOKABLE QStringList wrap(QString text, double width, double size, QString weight = "regular");
    Q_INVOKABLE double artWidth(QString key, double size, double tracking = 0, int count = -1);
    void text(QPainter &ctx, QString text, double x, double y, double size, QString weight, double tracking,
              QColor color);
    void art(QPainter &ctx, QString key, double x, double y, double size, int count, double tracking);
    QPainterPath path(const QString &svg);
    void commands(QPainter &ctx, const QJsonArray &commands, std::function<QImage(QString)> image);
    QImage label(const QJsonObject &item);

  private:
    QRecursiveMutex mutex;
    QHash<QString, Glyph> glyphs;
    QHash<QString, QList<Glyph>> lettering;
    QHash<QString, QRawFont> fonts;
    QCache<QString, QPainterPath> paths{1024};
    QCache<QString, double> widths{1024};
    QCache<QString, QStringList> wrapped{128 * 1024};
    Glyph glyph(QString ch, QString weight);
};

void saveImageNative(const QImage &image, const QString &path);
