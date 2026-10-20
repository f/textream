#pragma once

#include <QObject>
#include <QString>
#include <QUrl>

class FileManager : public QObject {
    Q_OBJECT

public:
    explicit FileManager(QObject *parent = nullptr);

    Q_INVOKABLE QString readTextFile(const QUrl &url);

    Q_PROPERTY(QString lastError READ lastError NOTIFY lastErrorChanged)

    QString lastError() const;

signals:
    void lastErrorChanged();

private:
    QString m_lastError;
    void setLastError(const QString &error);
};
