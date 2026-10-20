#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include "FileManager.h"
#include "audio/AudioCapture.h"
#include <QQuickStyle>

int main(int argc, char *argv[]) {
    QGuiApplication app(argc, argv);
    app.setApplicationName("Textream Linux");
    app.setOrganizationName("Textream Linux Community");
    QQuickStyle::setStyle("Fusion");
    FileManager fileManager;
    AudioCapture audioCapture;
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("fileManager", &fileManager);
    engine.rootContext()->setContextProperty("audioCapture", &audioCapture);
    engine.loadFromModule("TextreamLinux", "Main");
    if (engine.rootObjects().isEmpty()) return 1;
    return app.exec();
}
