# Migration Note: Stable Default Experience

This note describes how existing users are migrated into the new default behavior introduced in this pass.

## Migration Principles

- Existing saved settings win. The app does not overwrite previously chosen values.
- New defaults only apply to keys that were not saved before.
- Older presets and protocol fields remain compatible. No destructive migration is performed.

## Settings Compatibility

### TrackingGuard

- If a user already saved `matchWindowSize`, `advanceThreshold`, or `offScriptFreezeDelay`, those values are preserved.
- If those keys do not exist yet, the app uses the new conservative defaults:
  - `matchWindowSize = 6`
  - `advanceThreshold = 3.4`
  - `offScriptFreezeDelay = 0.9`
- `legacyTrackingFallbackEnabled` remains available and defaults to enabled, but it is only meant as a rollback guardrail. It does not define the default experience while `strictTrackingEnabled = true`.

### Persistent HUD

- If a user already configured `persistentHUDEnabled` or `hudModules`, those choices remain unchanged.
- If a user has never configured HUD preferences, the upgrade enables the minimal HUD:
  - `persistentHUDEnabled = true`
  - `hudModules = [trackingState, expectedWord]`
- In practice, this means users without an explicit HUD preference will see a small but visible HUD after upgrading.

### Attached Overlay

- `attachedFallbackBehavior` now defaults to `screenCorner`.
- `attachedHideWhenWindowUnavailable` now defaults to `false`, so attached mode prefers a visible fallback over silently disappearing.
- If a user already saved a target window id or label, the app still tries to rebind to that target. If the target is unavailable, the new behavior becomes an explicit fallback state instead of a silent failure.

## Preset Compatibility

- The recommended built-in presets are now limited to:
  - `Interview`
  - `Live Stream`
  - `Presentation`
- `Dual Display` and `Sidecar iPad` are not removed:
  - older `activeLayoutPreset` values still decode correctly
  - saved custom presets that reference them still work
  - they are simply no longer promoted as recommended starter presets
- If an existing user is still using `Dual Display` or `Sidecar iPad`, the app does not rewrite that choice. Settings can surface them as compatibility presets and let the user save them as custom presets if desired.

## Remote Compatibility

- Browser and Director payloads remain backward-compatible field extensions.
- Older clients can continue reading the existing fields:
  - `highlightedCharCount`
  - `words`
  - `audioLevels`
  - `lastSpokenText`
- Newer clients can additionally read:
  - `trackingState`
  - `confidenceLevel`
  - `expectedWord`
  - `nextCue`
  - `manualAsideActive`

## User-Visible Upgrade Impact

The most noticeable changes for existing users are:

1. Word tracking is more conservative and will freeze sooner before it guesses.
2. Attached mode is more likely to fall back to the screen corner than to appear to vanish.
3. Users without an explicit HUD preference now get a minimal HUD by default.
4. Settings recommends fewer presets, while preserving older saved presets.
