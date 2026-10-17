#pragma once
#include <QSettings>
#include <QString>

namespace AppStorage {
QString initializePortable(const QString &applicationDirectory);
QString executableDirectory();
QString dataDirectory();
QString cacheDirectory();
QString temporaryDirectory();
QSettings settings();
}
