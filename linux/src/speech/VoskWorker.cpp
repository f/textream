#include "VoskWorker.h"

#include <vosk_api.h>

#include <QJsonDocument>
#include <QJsonObject>
#include <QMutexLocker>
#include <QFileInfo>

VoskWorker::VoskWorker(
    const QString &modelPath,
    QObject *parent
)
    : QThread(parent),
      m_modelPath(modelPath) {}

void VoskWorker::enqueue(const QByteArray &pcm) {
    QMutexLocker lock(&m_mutex);

    if (m_stopping)
        return;

    if (m_queue.size() >= 32)
        m_queue.dequeue();

    m_queue.enqueue(pcm);
    m_condition.wakeOne();
}

void VoskWorker::requestStop() {
    QMutexLocker lock(&m_mutex);

    m_stopping = true;
    m_queue.clear();
    m_condition.wakeOne();
}

void VoskWorker::run() {
    const QFileInfo modelInfo(m_modelPath);

    if (!modelInfo.isDir()) {
        emit recognitionError(
            "Vosk model directory not found: " + m_modelPath
        );
        return;
    }

    vosk_set_log_level(-1);

    const QByteArray path =
        modelInfo.absoluteFilePath().toUtf8();

    VoskModel *model =
        vosk_model_new(path.constData());

    if (!model) {
        emit recognitionError("Unable to load Vosk model.");
        return;
    }

    VoskRecognizer *recognizer =
        vosk_recognizer_new(model, 16000.0f);

    if (!recognizer) {
        emit recognitionError(
            "Unable to initialize Vosk recognizer."
        );
        vosk_model_free(model);
        return;
    }

    while (true) {
        QByteArray pcm;

        {
            QMutexLocker lock(&m_mutex);

            while (m_queue.isEmpty() && !m_stopping)
                m_condition.wait(&m_mutex);

            if (m_stopping)
                break;

            pcm = m_queue.dequeue();
        }

        const bool completed =
            vosk_recognizer_accept_waveform(
                recognizer,
                pcm.constData(),
                pcm.size()
            );

        const char *json = completed
            ? vosk_recognizer_result(recognizer)
            : vosk_recognizer_partial_result(recognizer);

        const QJsonObject result =
            QJsonDocument::fromJson(
                QByteArray(json ? json : "")
            ).object();

        if (completed) {
            const QString text =
                result.value("text").toString();

            if (!text.isEmpty())
                emit finalText(text);

            emit partialText(QString());
        } else {
            emit partialText(
                result.value("partial").toString()
            );
        }
    }

    vosk_recognizer_free(recognizer);
    vosk_model_free(model);
}
