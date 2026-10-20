# Textream Linux — v0.1.0 prototype

Independent native Qt 6 Linux teleprompter prototype intended as the starting point for a Linux port of [f/textream](https://github.com/f/textream).

**Status:** source prototype; not yet compiled or GUI-tested in a Qt 6 desktop environment. This is a fresh implementation, not a mechanical translation of upstream Swift sources.

## Arch Linux / KDE Plasma 6

```bash
sudo pacman -S --needed base-devel cmake ninja qt6-base qt6-declarative qt6-quickcontrols2
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
./build/textream-linux
```

Optional install: `sudo cmake --install build` (defaults to `/usr/local`).

## Features
- Script editor and local `.txt`/`.md` file opening
- Floating frameless prompter, draggable via the top bar
- Adjustable scroll speed, font size, opacity, mirror and pause/restart
- Always-on-top requested using Qt window flags (compositor-dependent)

## Limitations
- No voice tracking, script saving, global shortcuts, microphone integration, or capture exclusion yet.
- Qt Wayland window placement, moving, and always-on-top support varies by compositor. KDE Plasma 6 Wayland is the first test target.
- Plain text file loading uses QML XMLHttpRequest; compatibility should be validated on target Qt versions.
- Editor text is not automatically saved when exiting.

## Upstream attribution
Textream by f: https://github.com/f/textream. This prototype contains newly authored Qt code. When incorporating upstream code/assets, retain the upstream MIT license and copyright notices. Verify upstream license before redistribution.
