cmake_minimum_required(VERSION 3.21)
project(textream-linux VERSION 0.1.0 LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
find_package(Qt6 6.4 REQUIRED COMPONENTS Quick QuickControls2 Multimedia)
qt_standard_project_setup(REQUIRES 6.4)
qt_add_executable(textream-linux
    src/main.cpp
    src/FileManager.cpp
    src/speech/VoskWorker.cpp
    src/speech/VoskWorker.h
    src/audio/AudioCapture.cpp
    src/audio/AudioCapture.h
    src/FileManager.h
)
qt_add_qml_module(textream-linux URI TextreamLinux VERSION 1.0 QML_FILES qml/Main.qml)
find_library(VOSK_LIBRARY NAMES vosk REQUIRED)

target_include_directories(textream-linux PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)

target_link_libraries(
    textream-linux PRIVATE ${VOSK_LIBRARY} Qt6::Quick Qt6::QuickControls2 Qt6::Multimedia)
install(TARGETS textream-linux RUNTIME DESTINATION bin)
install(FILES packaging/io.github.textreamlinux.desktop DESTINATION share/applications)
