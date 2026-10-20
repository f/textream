#pragma once

#include <QThread>
#include <QMutex>
#include <QWaitCondition>
#include <QByteArray>
#include <QQueue>
#include <QString>

class VoskWorker : public QThread {
    Q_OBJECT

public:
    explicit VoskWorker(
        const QString &modelPath,
        QObject *parent = nullptr
    );

    void enqueue(const QByteArray &pcm);
    void requestStop();

signals:
    void partialText(const QString &text);
    void finalText(const QString &text);
    void recognitionError(const QString &message);

protected:
    void run() override;

private:
    QString m_modelPath;
    QMutex m_mutex;
    QWaitCondition m_condition;
    QQueue<QByteArray> m_queue;
    bool m_stopping = false;
};
