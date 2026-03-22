# Slider-Based Window Sizing & Font Controls — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace fixed font size presets with continuous sliders and switch window width from pixels to screen percentages.

**Architecture:** Three settings properties change (`fontSizePreset` → `fontSize`, `notchWidth` → `windowWidthPercent`, new `fullscreenFontSize`). All consumers updated to use the new values. Settings UI switches from preset buttons to sliders.

**Tech Stack:** Swift, SwiftUI, AppKit (NSPanel)

**Spec:** `docs/superpowers/specs/2026-03-22-slider-sizing-fonts-design.md`

---

### Task 1: Update NotchSettings model

**Files:**
- Modify: `Textream/Textream/NotchSettings.swift`

- [ ] **Step 1: Remove FontSizePreset enum**

Delete lines 10–34 (the entire `FontSizePreset` enum).

- [ ] **Step 2: Replace fontSizePreset property with fontSize**

Replace:
```swift
var fontSizePreset: FontSizePreset {
    didSet { UserDefaults.standard.set(fontSizePreset.rawValue, forKey: "fontSizePreset") }
}
```
With:
```swift
var fontSize: CGFloat {
    didSet { UserDefaults.standard.set(Double(fontSize), forKey: "fontSize") }
}
```

- [ ] **Step 3: Add fullscreenFontSize property**

Add after `fontSize`:
```swift
var fullscreenFontSize: CGFloat {
    didSet { UserDefaults.standard.set(Double(fullscreenFontSize), forKey: "fullscreenFontSize") }
}
```

- [ ] **Step 4: Replace notchWidth with windowWidthPercent**

Replace:
```swift
var notchWidth: CGFloat {
    didSet { UserDefaults.standard.set(Double(notchWidth), forKey: "notchWidth") }
}
```
With:
```swift
var windowWidthPercent: CGFloat {
    didSet { UserDefaults.standard.set(Double(windowWidthPercent), forKey: "windowWidthPercent") }
}
```

- [ ] **Step 5: Update font computed property**

Replace:
```swift
var font: NSFont {
    fontFamilyPreset.font(size: fontSizePreset.pointSize)
}
```
With:
```swift
var font: NSFont {
    fontFamilyPreset.font(size: fontSize)
}
```

- [ ] **Step 6: Update constants**

Replace `defaultWidth`, `minWidth`, `maxWidth` while preserving `defaultHeight`, `defaultLocale`, `minHeight`, `maxHeight`:
```swift
static let defaultWindowWidthPercent: CGFloat = 0.4
static let defaultFontSize: CGFloat = 20
static let defaultFullscreenFontSize: CGFloat = 72
static let defaultHeight: CGFloat = 150
static let defaultLocale: String = Locale.current.identifier

static let minHeight: CGFloat = 100
static let maxHeight: CGFloat = 400
```

- [ ] **Step 7: Update init()**

Replace the `notchWidth` initialization:
```swift
let savedWidth = UserDefaults.standard.double(forKey: "notchWidth")
self.notchWidth = savedWidth > 0 ? CGFloat(savedWidth) : Self.defaultWidth
```
With:
```swift
let savedWidthPercent = UserDefaults.standard.double(forKey: "windowWidthPercent")
self.windowWidthPercent = savedWidthPercent > 0 ? CGFloat(savedWidthPercent) : Self.defaultWindowWidthPercent
```

Replace the `fontSizePreset` initialization:
```swift
self.fontSizePreset = FontSizePreset(rawValue: UserDefaults.standard.string(forKey: "fontSizePreset") ?? "") ?? .lg
```
With:
```swift
let savedFontSize = UserDefaults.standard.double(forKey: "fontSize")
self.fontSize = savedFontSize > 0 ? CGFloat(savedFontSize) : Self.defaultFontSize
let savedFullscreenFontSize = UserDefaults.standard.double(forKey: "fullscreenFontSize")
self.fullscreenFontSize = savedFullscreenFontSize > 0 ? CGFloat(savedFullscreenFontSize) : Self.defaultFullscreenFontSize
```

- [ ] **Step 8: Commit**

```bash
git add Textream/Textream/NotchSettings.swift
git commit -m "refactor: replace font size presets and pixel width with slider-backed settings"
```

### Task 2: Update NotchOverlayController window sizing

**Files:**
- Modify: `Textream/Textream/NotchOverlayController.swift`

- [ ] **Step 1: Update showPinned()**

In `showPinned(settings:screen:)`, replace:
```swift
let notchWidth = settings.notchWidth
```
With:
```swift
let notchWidth = screenFrame.width * settings.windowWidthPercent
```

Note: `screenFrame` is already available in this method. The rest of the method uses `notchWidth` locally so no further changes needed.

- [ ] **Step 2: Update showFloating()**

In `showFloating(settings:screenFrame:)`, replace:
```swift
let panelWidth = settings.notchWidth
```
With:
```swift
let panelWidth = screenFrame.width * settings.windowWidthPercent
```

Replace the min/max size lines:
```swift
panel.minSize = NSSize(width: 280, height: panelHeight)
panel.maxSize = NSSize(width: 500, height: panelHeight + 350)
```
With:
```swift
panel.minSize = NSSize(width: screenFrame.width * 0.2, height: panelHeight)
panel.maxSize = NSSize(width: screenFrame.width * 0.8, height: panelHeight + 350)
```

- [ ] **Step 3: Update showFollowCursor()**

In `showFollowCursor(settings:screen:)`, replace:
```swift
let panelWidth = settings.notchWidth
```
With:
```swift
let panelWidth = screen.frame.width * settings.windowWidthPercent
```

- [ ] **Step 4: Update updateFrameTracker()**

In `NotchOverlayView.updateFrameTracker()`, replace:
```swift
let fullWidth = NotchSettings.shared.notchWidth
```
With:
```swift
let fullWidth = (NSScreen.main?.frame.width ?? 1440) * NotchSettings.shared.windowWidthPercent
```

- [ ] **Step 5: Commit**

```bash
git add Textream/Textream/NotchOverlayController.swift
git commit -m "refactor: use percentage-based window width in all overlay modes"
```

### Task 3: Update ExternalDisplayController fullscreen font

**Files:**
- Modify: `Textream/Textream/ExternalDisplayController.swift`

- [ ] **Step 1: Replace hardcoded font calculation**

In `ExternalDisplayView.prompterView`, replace:
```swift
let fontSize = max(48, min(96, geo.size.width / 14))
```
and:
```swift
font: .systemFont(ofSize: fontSize, weight: .semibold),
```
With:
```swift
let fontSize = NotchSettings.shared.fullscreenFontSize
```
and (using `fontFamilyPreset.font` directly instead of `settings.font`, since `settings.font` uses `fontSize` for pinned/floating, not fullscreen):
```swift
font: NotchSettings.shared.fontFamilyPreset.font(size: fontSize),
```

- [ ] **Step 2: Commit**

```bash
git add Textream/Textream/ExternalDisplayController.swift
git commit -m "feat: use user-controlled font size and family for fullscreen teleprompter"
```

### Task 4: Update SettingsView UI

**Files:**
- Modify: `Textream/Textream/SettingsView.swift`

- [ ] **Step 1: Update settings panel sizing**

In the settings panel setup (~line 35), replace:
```swift
let maxWidth = NotchSettings.maxWidth
```
With:
```swift
let maxWidth: CGFloat = 500
```

Also update line 38 and 46 if they reference `NotchSettings.maxWidth` — use the local `maxWidth` constant instead (they likely already do).

- [ ] **Step 2: Replace font size preset picker with slider**

Replace the entire font size preset picker section (lines ~485–517):
```swift
// Text Size
Text("Size")
    .font(.system(size: 13, weight: .medium))

HStack(spacing: 8) {
    ForEach(FontSizePreset.allCases) { preset in
        ...
    }
}
```
With:
```swift
// Text Size
VStack(alignment: .leading, spacing: 4) {
    HStack {
        Text("Font Size")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        Spacer()
        Text("\(Int(settings.fontSize))pt")
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(.tertiary)
    }
    Slider(
        value: $settings.fontSize,
        in: 14...48,
        step: 1
    )
}

Text("Ag")
    .font(Font(settings.fontFamilyPreset.font(size: settings.fontSize)))
    .foregroundStyle(.primary)
    .frame(maxWidth: .infinity, alignment: .center)
    .padding(.vertical, 4)
```

- [ ] **Step 3: Replace width pixel slider with percentage slider**

Replace the width slider section (lines ~630–644):
```swift
VStack(alignment: .leading, spacing: 4) {
    HStack {
        Text("Width")
            ...
        Text("\(Int(settings.notchWidth))px")
            ...
    }
    Slider(
        value: $settings.notchWidth,
        in: NotchSettings.minWidth...NotchSettings.maxWidth,
        step: 10
    )
}
```
With:
```swift
VStack(alignment: .leading, spacing: 4) {
    HStack {
        Text("Width")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        Spacer()
        Text("\(Int(settings.windowWidthPercent * 100))%")
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(.tertiary)
    }
    Slider(
        value: $settings.windowWidthPercent,
        in: 0.2...0.8,
        step: 0.05
    )
}
```

- [ ] **Step 4: Add fullscreen font size slider**

After the width/height dimensions section (after the height slider, before the closing braces), add:
```swift
Divider()

// Fullscreen Font Size
VStack(alignment: .leading, spacing: 4) {
    HStack {
        Text("Fullscreen Font Size")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        Spacer()
        Text("\(Int(settings.fullscreenFontSize))pt")
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(.tertiary)
    }
    Slider(
        value: $settings.fullscreenFontSize,
        in: 32...200,
        step: 2
    )
}
```

- [ ] **Step 5: Update notchWidth references in SettingsView preview**

In `SettingsPreviewController.cursorFrame(for:settings:)` (~line 109), replace:
```swift
let notchWidth = settings.notchWidth
```
With:
```swift
let notchWidth = panel.frame.width * settings.windowWidthPercent
```

In `NotchPreviewContent.body` (~line 157), replace:
```swift
let currentWidth = settings.notchWidth
```
With:
```swift
let screenWidth = NSScreen.main?.frame.width ?? 1440
let currentWidth = screenWidth * settings.windowWidthPercent
```

At ~line 217, replace:
```swift
.animation(.easeInOut(duration: 0.15), value: settings.notchWidth)
```
With:
```swift
.animation(.easeInOut(duration: 0.15), value: settings.windowWidthPercent)
```

- [ ] **Step 6: Update resetAllSettings()**

Replace:
```swift
settings.notchWidth = NotchSettings.defaultWidth
```
With:
```swift
settings.windowWidthPercent = NotchSettings.defaultWindowWidthPercent
```

Replace:
```swift
settings.fontSizePreset = .lg
```
With:
```swift
settings.fontSize = NotchSettings.defaultFontSize
settings.fullscreenFontSize = NotchSettings.defaultFullscreenFontSize
```

- [ ] **Step 7: Commit**

```bash
git add Textream/Textream/SettingsView.swift
git commit -m "feat: replace font size presets with sliders, add fullscreen font control"
```

### Task 5: Build and verify

- [ ] **Step 1: Build the project**

```bash
cd /Users/monster/dev/textream && xcodebuild -project Textream/Textream.xcodeproj -scheme Textream -configuration Debug build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED. If there are compilation errors referencing `FontSizePreset`, `notchWidth`, or `maxWidth`, fix them — these are leftover references to removed symbols.

- [ ] **Step 2: Fix any remaining references**

Search for any remaining references to the removed symbols:
- `FontSizePreset` — should only appear in `BrowserFontSizePreset` context (which is separate)
- `notchWidth` — should be zero occurrences
- `fontSizePreset` — should be zero occurrences
- `NotchSettings.maxWidth`, `NotchSettings.minWidth`, `NotchSettings.defaultWidth` — should be zero occurrences
- `settings.notchWidth` — should be zero occurrences

- [ ] **Step 3: Launch and test**

Build and launch from CLI:
```bash
cd /Users/monster/dev/textream && xcodebuild -project Textream/Textream.xcodeproj -scheme Textream -configuration Debug build 2>&1 | tail -5 && open "$(xcodebuild -project Textream/Textream.xcodeproj -scheme Textream -configuration Debug -showBuildSettings 2>/dev/null | grep ' BUILT_PRODUCTS_DIR' | awk '{print $3}')/Textream.app"
```

Manual verification:
1. Open Settings → check font size slider works (14–48pt range)
2. Check width slider shows percentages (20%–80%)
3. Check fullscreen font size slider present (32–200pt)
4. Start pinned overlay → verify width matches percentage
5. Start floating overlay → verify resizable within percentage bounds
6. Start fullscreen → verify font size matches slider value
7. Reset all settings → verify defaults restored

- [ ] **Step 4: Commit any fixes**

```bash
git add -A && git commit -m "fix: resolve remaining references to removed font size presets"
```
