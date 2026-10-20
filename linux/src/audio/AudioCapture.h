#pragma once

#include <QObject>
#include <QAudioSource>
#include <QMediaDevices>
#include <QAudioDevice>
#include <QIODevice>
#include <QStringList>
#include <memory>
#include "speech/VoskWorker.h"

class AudioCapture : public QObject {
    Q_OBJECT
    Q_PROPERTY(qreal level READ level NOTIFY levelChanged)
    Q_PROPERTY(bool recording READ recording NOTIFY recordingChanged)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)
    Q_PROPERTY(QStringList devices READ devices NOTIFY devicesChanged)

public:
    explicit AudioCapture(QObject *parent = nullptr);

    qreal level() const { return m_level; }
    bool recording() const { return m_recording; }
    QString error() const { return m_error; }

    Q_PROPERTY(
        QString partialTranscript
        READ partialTranscript
        NOTIFY transcriptChanged
    )

    Q_PROPERTY(
        QString finalTranscript
        READ finalTranscript
        NOTIFY transcriptChanged
    )

    QString partialTranscript() const {
        return m_partialTranscript;
    }

    QString finalTranscript() const {
        return m_finalTranscript;
    }
    QStringList devices() const;

    Q_INVOKABLE void start(int index);
    Q_INVOKABLE void stop();

signals:
    void levelChanged();
    void recordingChanged();
    void errorChanged();
    void devicesChanged();
    void transcriptChanged();

private:
    void processAudio();
    void setError(const QString &message);

    QMediaDevices m_mediaDevices;
    std::unique_ptr<QAudioSource> m_source;
    QIODevice *m_io = nullptr;
    QByteArray m_pending;
    qreal m_level = 0.0;
    bool m_recording = false;
    bool m_stoppingCapture = false;
    QString m_error;
    QString m_partialTranscript;
    QString m_finalTranscript;
    std::unique_ptr<VoskWorker> m_worker;
};
