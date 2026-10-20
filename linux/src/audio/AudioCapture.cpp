#include "AudioCapture.h"

#include <QAudioFormat>
#include <QtGlobal>
#include <cmath>
#include <cstring>
#include <algorithm>
#include <QDebug>
#include <QStandardPaths>

AudioCapture::AudioCapture(QObject *parent)
    : QObject(parent) {
    connect(&m_mediaDevices, &QMediaDevices::audioInputsChanged,
            this, &AudioCapture::devicesChanged);
}

QStringList AudioCapture::devices() const {
    QStringList result;
    for (const auto &device : QMediaDevices::audioInputs())
        result.append(device.description());
    return result;
}

void AudioCapture::setError(const QString &message) {
    if (m_error == message) return;
    m_error = message;
    emit errorChanged();
}

void AudioCapture::start(int index) {
    stop();
    setError({});

    const auto inputs = QMediaDevices::audioInputs();
    if (index < 0 || index >= inputs.size()) {
        setError("No valid microphone selected.");
        return;
    }

    const QAudioDevice device = inputs.at(index);
    QAudioFormat format;
    format.setSampleRate(16000);
    format.setChannelCount(1);
    format.setSampleFormat(QAudioFormat::Int16);

    if (!device.isFormatSupported(format)) {
        format = device.preferredFormat();
    }

    if (format.sampleFormat() != QAudioFormat::Int16 &&
        format.sampleFormat() != QAudioFormat::Float) {
        setError("Unsupported microphone sample format.");
        return;
    }

    qInfo() << "Textream capture format:"
            << "device=" << device.description()
            << "rate=" << format.sampleRate()
            << "channels=" << format.channelCount()
            << "sampleFormat=" << format.sampleFormat();

    if (format.sampleRate() != 16000 ||
        format.channelCount() != 1 ||
        format.sampleFormat() != QAudioFormat::Int16) {

        setError(
            "Speech recognition requires 16 kHz mono Int16. "
            "Please select a compatible microphone."
        );
        return;
    }

    const QString modelPath =
        QStandardPaths::writableLocation(
            QStandardPaths::GenericDataLocation
        ) + "/textream/models/vosk-model-small-en-us-0.15";

    m_worker = std::make_unique<VoskWorker>(modelPath);

    m_partialTranscript.clear();
    m_finalTranscript.clear();
    emit transcriptChanged();

    connect(
        m_worker.get(),
        &VoskWorker::partialText,
        this,
        [this](const QString &text) {
            m_partialTranscript = text;
            emit transcriptChanged();
        }
    );

    connect(
        m_worker.get(),
        &VoskWorker::finalText,
        this,
        [this](const QString &text) {
            if (!m_finalTranscript.isEmpty())
                m_finalTranscript += " ";

            m_finalTranscript += text;

            // Keep only recent finalized speech.
            // Voice tracking uses the latest recognized words.
            constexpr qsizetype maxTranscriptChars = 2048;

            if (m_finalTranscript.size() > maxTranscriptChars) {
                const qsizetype excess =
                    m_finalTranscript.size() - maxTranscriptChars;

                const qsizetype boundary =
                    m_finalTranscript.indexOf(' ', excess);

                if (boundary >= 0) {
                    m_finalTranscript.remove(0, boundary + 1);
                } else {
                    m_finalTranscript =
                        m_finalTranscript.right(maxTranscriptChars);
                }
            }

            emit transcriptChanged();
        }
    );

    connect(
        m_worker.get(),
        &VoskWorker::recognitionError,
        this,
        [this](const QString &message) {
            setError(message);
            stop();
        }
    );

    m_worker->start();

    m_source =
        std::make_unique<QAudioSource>(device, format);
    m_source->setBufferSize(format.bytesForDuration(100000));

    m_io = m_source->start();
    if (!m_io) {
        setError("Unable to start microphone capture.");
        stop();
        return;
    }

    connect(m_io, &QIODevice::readyRead,
            this, &AudioCapture::processAudio);

    connect(m_source.get(), &QAudioSource::stateChanged,
            this, [this](QAudio::State state) {
        if (state == QAudio::StoppedState &&
            m_source && m_source->error() != QAudio::NoError) {
            setError("Microphone capture stopped unexpectedly.");
            stop();
        }
    });

    m_recording = true;
    emit recordingChanged();
}

void AudioCapture::processAudio() {
    if (!m_io || !m_source) return;

    const auto format = m_source->format();
    const int bytesPerSample = format.bytesPerSample();
    if (bytesPerSample <= 0) return;

    m_pending.append(m_io->readAll());

    const int completeBytes =
        (m_pending.size() / bytesPerSample) * bytesPerSample;
    if (!completeBytes) return;

    double sum = 0;
    const int count = completeBytes / bytesPerSample;

    for (int i = 0; i < count; ++i) {
        double value = 0;
        const char *p = m_pending.constData() + i * bytesPerSample;

        if (format.sampleFormat() == QAudioFormat::Int16) {
            qint16 sample;
            std::memcpy(&sample, p, sizeof(sample));
            value = sample / 32768.0;
        } else {
            float sample;
            std::memcpy(&sample, p, sizeof(sample));
            value = sample;
        }

        sum += value * value;
    }

    if (m_worker)
        m_worker->enqueue(
            m_pending.left(completeBytes)
        );

    m_pending.remove(0, completeBytes);

    const double rms = std::sqrt(sum / count);
    m_level = std::clamp(rms * 5.0, 0.0, 1.0);
    emit levelChanged();
}

void AudioCapture::stop() {
    if (m_stoppingCapture)
        return;

    m_stoppingCapture = true;

    if (m_source) {
        m_source->stop();
        m_io = nullptr;
        m_source.reset();
    }

    if (m_worker) {
        m_worker->requestStop();
        m_worker->wait();
        m_worker.reset();
    }

    m_pending.clear();
    if (m_level != 0) {
        m_level = 0;
        emit levelChanged();
    }

    if (m_recording) {
        m_recording = false;
        emit recordingChanged();
    }

    m_stoppingCapture = false;
}
