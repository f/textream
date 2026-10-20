# Textream for Linux

A native Qt 6 teleprompter for Linux, based on the concept of
[Textream by f](https://github.com/f/textream).

**Version:** 0.1.0 development preview
**Tested on:** Arch Linux, KDE Plasma 6, Wayland

## Features

- Script editor with local TXT/Markdown file opening
- Floating, draggable and resizable teleprompter
- Adjustable font size, speed, opacity and mirroring
- Manual scrolling and playback controls
- Always-on-top option (compositor-dependent)
- Offline Vosk speech recognition
- Microphone selection and audio level indicator
- Automatic voice-following scrolling
- Current-word highlighting
- Forward-only speech recovery
- Reading-position guide and progress indicator
- Persistent preferences and optional microphone auto-start

## Requirements

- CMake 3.21+
- C++17 compiler and Ninja
- Qt 6.4+ with Quick, Quick Controls 2 and Multimedia
- Vosk shared library
- Compatible microphone
- Vosk English speech-recognition model

## Arch Linux dependencies

Install the build and Qt dependencies:

    sudo pacman -S --needed base-devel cmake ninja qt6-base qt6-declarative qt6-quickcontrols2 qt6-multimedia

The Vosk shared library must also be installed. It is located
by CMake using find_library(), not pkg-config.

## Build and run

From the repository root:

    cmake -S linux -B linux/build -G Ninja -DCMAKE_BUILD_TYPE=Release
    cmake --build linux/build
    ./linux/build/textream-linux

## Offline speech recognition

Download the English model `vosk-model-small-en-us-0.15`
from https://alphacephei.com/vosk/models

Extract the model directory to:

    ~/.local/share/textream/models/vosk-model-small-en-us-0.15/

The model files must be directly inside that directory.

Speech recognition runs locally, without a cloud account.

## Voice-following usage

1. Open or paste your script.
2. Open the floating teleprompter.
3. Select your microphone.
4. Enable voice-following.
5. Start microphone capture.
6. Read the script aloud.

Textream highlights recognized words and adjusts scrolling
to follow your position.

Forward sentence-skipping recovery is supported.
Backward recovery is not currently implemented.

## Install

After building:

    sudo cmake --install linux/build

The default installation prefix is `/usr/local`.

## Current limitations

- KDE Plasma 6 Wayland is the primary tested environment.
- Window positioning and always-on-top behavior vary by compositor.
- The current speech model supports English.
- Microphone capture requires 16 kHz mono Int16 audio.
- Automatic saving of edited scripts is not implemented.
- Capture exclusion and global shortcuts are not yet supported.
- This is a development preview, not a stable release.

## Development

Linux implementation files are contained in `linux/`.
The existing macOS application remains separate.

## License and attribution

Original project: https://github.com/f/textream

See the repository's root LICENSE for applicable license terms.
