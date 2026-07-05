# Slider-Based Window Sizing & Font Controls

**Date:** 2026-03-22
**Status:** Draft

## Summary

Replace fixed font size presets (XS/SM/LG/XL) with continuous sliders, switch window width from pixel values to screen percentages (20–80%), and add user-controllable font size for fullscreen teleprompter.

## Changes

### 1. Settings Model (NotchSettings.swift)

**Remove:**
- `FontSizePreset` enum (XS 14pt, SM 16pt, LG 20pt, XL 24pt)
- `fontSizePreset` property and its UserDefaults persistence
- `defaultWidth`, `minWidth`, `maxWidth` constants (340px, 310px, 500px)

**Add:**
- `fontSize: CGFloat` — pinned/floating font size. Default 20, range 14–48. Persisted to UserDefaults.
- `fullscreenFontSize: CGFloat` — fullscreen font size. Default 72, range 32–200. Persisted to UserDefaults.
- `defaultWindowWidthPercent: CGFloat` = 0.4

**Replace:**
- `notchWidth: CGFloat` (pixel value) → `windowWidthPercent: CGFloat` (default 0.4, range 0.2–0.8). Persisted to UserDefaults.

**Update:**
- `font` computed property: use `fontSize` directly instead of `fontSizePreset.pointSize`
- `resetAllSettings()`: reset `fontSize` to 20, `fullscreenFontSize` to 72, `windowWidthPercent` to 0.4 (replacing old `notchWidth` and `fontSizePreset` resets)

**Unchanged:** `FontFamilyPreset`, `FontColorPreset`, `CueBrightness`, `textAreaHeight`

### 2. Window Sizing (NotchOverlayController.swift)

**Pinned window (`showPinned()`):**
- Width = `screen.frame.width * settings.windowWidthPercent`
- Height unchanged (textAreaHeight-based)

**Floating window (`showFloating()`):**
- Width = `screen.frame.width * settings.windowWidthPercent`
- Remove hardcoded 500px max constraint
- `panel.minSize`: width = `screen.frame.width * 0.2`
- `panel.maxSize`: width = `screen.frame.width * 0.8`

**Follow cursor (`showFollowCursor()`):**
- Same percentage-based width calculation as pinned/floating

**`updateFrameTracker()` in NotchOverlayView:**
- Update to use `settings.windowWidthPercent * screen.frame.width` instead of `settings.notchWidth`

**Fullscreen:** Unchanged (already fills screen)

### 3. Fullscreen Font (ExternalDisplayController.swift)

- Replace `max(48, min(96, geo.size.width / 14))` with `settings.fullscreenFontSize`
- Use `settings.font` (respecting `fontFamilyPreset`) instead of hardcoded `.systemFont`

### 4. Settings UI (SettingsView.swift)

**Replace font size preset picker** (4 XS/SM/LG/XL buttons) with:
- "Font Size" slider, range 14–48pt, shows current value
- Live preview text sample using slider value

**Replace width pixel slider** (310–500px) with:
- "Window Width" slider, range 20%–80%, shows current percentage

**Add:**
- "Fullscreen Font Size" slider, range 32–200pt, shows current value

**Update:**
- Settings panel sizing: replace `NotchSettings.maxWidth` references with a fixed reasonable width (e.g., 500px) for the settings window itself
- `resetAllSettings()` button: update to reset new properties

**Unchanged:** Font family picker, height slider, color pickers, cue brightness

## Migration

Existing UserDefaults keys for `fontSizePreset` and `notchWidth` become stale. New keys (`fontSize`, `fullscreenFontSize`, `windowWidthPercent`) initialize to defaults on first launch. No migration needed — old values are simply ignored.

## Files Changed

| File | Change |
|------|--------|
| `NotchSettings.swift` | Remove FontSizePreset enum, add slider-backed properties, update defaults/reset |
| `NotchOverlayController.swift` | Percentage-based width in showPinned, showFloating, showFollowCursor, updateFrameTracker |
| `ExternalDisplayController.swift` | Use settings.fullscreenFontSize and settings.font |
| `SettingsView.swift` | Replace preset buttons with sliders, fix settings panel sizing |
