# Textream Stable Defaults

This document captures the recommended defaults for the "stable by default" product pass. The intent is simple:

- stop before drifting
- fall back to the screen corner when attached anchoring fails
- keep the default HUD minimal
- keep built-in presets intentionally small

## TrackingGuard

| Parameter | Recommended Default | Notes |
| --- | --- | --- |
| `strictTrackingEnabled` | `true` | Enables Guarded Word Tracking by default. |
| `legacyTrackingFallbackEnabled` | `true` | Keeps the legacy path available, but only when `strictTrackingEnabled = false`. |
| `manualAsideHotkey` | `optionDoubleTap` | Double-tap `Option` to toggle `Aside`. |
| `temporaryIgnoreHotkey` | `fnHold` | Hold `Fn` to freeze tracking temporarily. |
| `matchWindowSize` | `6` | Narrows the matching window to reduce off-script advancement. |
| `advanceThreshold` | `3.4` | Raises the advancement threshold so the system prefers freezing over guessing. |
| `offScriptFreezeDelay` | `0.9` | Enter `lost` after roughly 0.9 seconds of missed matches across consecutive frames. |

## Attached Overlay

| Parameter | Recommended Default | Notes |
| --- | --- | --- |
| `attachedAnchorCorner` | `topRight` | Default corner for attached placement. |
| `attachedMarginX` | `16` | Horizontal inset from the target corner. |
| `attachedMarginY` | `14` | Vertical inset from the target corner. |
| `attachedFallbackBehavior` | `screenCorner` | Falls back to the screen corner instead of disappearing. |
| `attachedHideWhenWindowUnavailable` | `false` | Keeps fallback visible so the user can understand what happened. |
| `attachedTargetWindowID` | `0` | No target window is preselected on first launch. |
| `attachedTargetWindowLabel` | `""` | No saved target label on first launch. |
| `hasSeenAttachedOnboarding` | `false` | Show attached onboarding the first time the mode is used. |

## Layout Presets

The recommended built-in preset set is intentionally limited to three templates:

| Preset | Overlay | HUD | Use Case |
| --- | --- | --- | --- |
| `Interview` | `floating` | `trackingState` | Small and restrained, suitable for meetings or interviews. |
| `Live Stream` | `attached` | `trackingState + expectedWord` | Optimized for attached usage where state and current cue matter most. |
| `Presentation` | `pinned` | `trackingState + expectedWord` | Larger and higher contrast for speaking and presenting. |

Compatibility-only presets remain available:

- `Dual Display`
- `Sidecar iPad`

They are still recognized in saved settings, but they are no longer promoted as the recommended starter set.

## Persistent HUD

| Parameter | Recommended Default | Notes |
| --- | --- | --- |
| `activeLayoutPreset` | `custom` | The baseline startup experience does not force a preset. |
| `persistentHUDEnabled` | `true` | A minimal HUD is enabled by default to explain tracking and fallback state. |
| `hudModules` | `[trackingState, expectedWord]` | Keep the default HUD focused on state and the current expected word. |

## Experience Summary

- The app starts from a neutral `custom` layout instead of forcing a scenario preset.
- The HUD is on by default, but only shows the two highest-value signals.
- Attached mode falls back to the screen corner when it loses a stable anchor.
- Strict tracking is intentionally conservative and freezes sooner than it advances.
