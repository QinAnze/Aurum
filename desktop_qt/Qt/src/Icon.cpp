#include <QDir>
#include <QFile>
// 图标直接使用原版无重采样的 PNG，避免不同系统绘图器改变阴影与轮廓。
int makeIcon(const QString &directory) {
    QDir().mkpath(directory);
    for (int size : {16, 32, 64, 128, 256, 512, 1024}) {
        const auto name = QString("icon-%1.png").arg(size);
        const auto output = directory + "/" + name;
        QFile::remove(output);
        if (!QFile::copy(":/icons/" + name, output)) {
            return 1;
        }
    }
    return 0;
}
