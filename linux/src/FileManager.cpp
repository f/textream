#include "FileManager.h"

#include <QFile>
#include <QFileInfo>

FileManager::FileManager(QObject *parent)
    : QObject(parent) {}

QString FileManager::lastError() const {
    return m_lastError;
}

void FileManager::setLastError(const QString &error) {
    if (m_lastError == error)
        return;

    m_lastError = error;
    emit lastErrorChanged();
}

QString FileManager::readTextFile(const QUrl &url) {
    setLastError(QString());

    if (!url.isValid() || !url.isLocalFile()) {
        setLastError(QStringLiteral("Only local files are supported."));
        return QString();
    }

    const QString path = url.toLocalFile();
    QFileInfo info(path);

    if (!info.isFile()) {
        setLastError(QStringLiteral("The selected path is not a regular file."));
        return QString();
    }

    QFile file(path);

    if (!file.open(QIODevice::ReadOnly)) {
        setLastError(file.errorString());
        return QString();
    }

    const QByteArray data = file.readAll();

    if (file.error() != QFileDevice::NoError) {
        setLastError(file.errorString());
        return QString();
    }

    return QString::fromUtf8(data);
}
