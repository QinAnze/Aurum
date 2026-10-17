#pragma once
#include "AurumSpectrum.h"
#include <QColor>
#include <QElapsedTimer>
#include <QJsonArray>
#include <QRectF>
#include <QString>
#include <QVector>
#include <array>
#include <memory>
#include <random>

/// Aurum 魔法书词云（移植自 aurum_flutter/lib/effects/word_cloud.dart）。
///
/// 生命周期：rise(重力减速上升 850ms) → hold(停留 4.2~8s) → fall(自由落体 1150ms)；
/// 换行不硬清场（dropAll 错落坠落）；碰撞检测 + 封面圆禁区；句末最后两个词显著放大；
/// 按歌词时间轴出场；极克制的描边光（仅超频）。
namespace aurum {

class WordCloud {
  public:
    WordCloud();

    /// 清空所有活词（切歌 / 关闭特效时调用）。
    void reset();
    bool hasActive() const { return !m_words.isEmpty(); }

    /// 播放进度驱动（对应 cloudTick）。tMs 为当前播放位置（毫秒），
    /// lines 为歌词行 [{text, startMs, translation?}]。env 提供画布与封面禁区。
    void tick(double tMs, const QJsonArray &lines, double width, double height, double climax, bool oc,
              const QRectF *coverRect);

    /// 推进相位、移除坠完的词（对应 advance）。返回是否还有活词。
    bool advance();

    /// 绘制全部活词（对应 WordCloudPainter.paint）。
    void draw(HudOp op, double width, double height, double climax, bool oc) const;

    /// 注入字形宽度测量（由宿主提供 Glyphs::width）。
    void setMeasure(std::function<double(const QString &, double)> measure) { m_measure = std::move(measure); }

  private:
    struct Word {
        QString text;
        double x = 0, y = 0, size = 0;
        bool vertical = false;
        QColor color;
        QString phase = "rise"; // rise | hold | fall
        double t0 = 0;          // ms（墙钟）
        double startY = 0;
        double holdMs = 0;
        double fallFrom = 0;
    };
    struct Rect {
        double x, y, w, h;
    };

    void dropAll();
    void spawn(const QString &word, double t0, int idx, int total, double w, double h, double climax, bool oc,
               const QColor *colors, int colorCount, const QRectF *coverRect);
    QSizeF measureWord(const QString &word, bool vertical, double size) const;

    QVector<Word> m_words;
    QElapsedTimer m_clock;
    std::mt19937 m_rng;
    QVector<Rect> m_placed;
    QStringList m_chars;
    int m_line = -1;
    int m_revealed = 0;
    QVector<double> m_spawnTimes;
    double m_nowMs = 0;
    std::function<double(const QString &, double)> m_measure;
};

} // namespace aurum
