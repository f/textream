# Browser Remote Text Size Setting

## Summary

Add a user-configurable text size setting for the browser remote viewer. Currently the browser remote hardcodes font size via `clamp(48px, calc(100vw/14), 96px)`. This feature adds a four-preset picker (SM/MD/LG/XL) in the Mac app's Settings > Remote tab, allowing the presenter to control how large text appears on the remote viewing device.

## Motivation

Different viewing distances and screen sizes benefit from different text sizes. A phone held in hand needs smaller text than a TV across the room. The current one-size-fits-all formula doesn't accommodate this.

## Design

### Data Model (`NotchSettings.swift`)

Add a new enum `BrowserFontSizePreset: String, CaseIterable, Identifiable` (matching existing enum patterns) with four cases:

| Case | Label | Desktop CSS `clamp()` | Mobile (`<=768px`) CSS `clamp()` |
|------|-------|----------------------|----------------------------------|
| `.sm` | SM | `clamp(24px, calc(100vw/22), 48px)` | `clamp(18px, calc(100vw/16), 36px)` |
| `.md` | MD | `clamp(32px, calc(100vw/18), 54px)` | `clamp(22px, calc(100vw/13), 42px)` |
| `.lg` | LG | `clamp(40px, calc(100vw/14), 60px)` | `clamp(28px, calc(100vw/10), 48px)` |
| `.xl` | XL | `clamp(48px, calc(100vw/12), 64px)` | `clamp(34px, calc(100vw/8), 56px)` |

Add computed properties `cssClamp` and `mobileCssClamp` on the enum returning the formula strings (following the pattern of `FontColorPreset.cssColor`).

Add a new persisted property on `NotchSettings`:

```swift
var browserFontSizePreset: BrowserFontSizePreset  // default: .lg
```

Default is `.lg` because the current hardcoded formula `clamp(48px, calc(100vw/14), 96px)` most closely matches the `.lg` preset's divisor (`100vw/14`), preserving a similar experience for existing users. The max value will be lower (60px vs 96px) per the user's requested size range (24-64px).

Persisted to UserDefaults with key `"browserFontSizePreset"`, using the standard `didSet`/`init` pattern used by all other settings properties.

### Settings UI (`SettingsView.swift`)

- Add a segmented picker labeled "Remote Text Size" with options SM / MD / LG / XL
- Placement: in the Remote tab (`browserTab`), below the URL/copy-button row (after line 1073), above the `DisclosureGroup("Advanced", ...)` (line 1075)
- Only visible when `browserServerEnabled` is true
- Styled consistently with existing pickers in the app

### Browser Remote (`BrowserServer.swift`)

- Read `NotchSettings.shared.browserFontSizePreset` when generating the HTML page
- Use the enum's `cssClamp` property for the `#text-container` font-size rule (replacing current `clamp(48px,calc(100vw / 14),96px)`)
- Use the enum's `mobileCssClamp` property for the `@media(max-width:768px)` breakpoint rule (replacing current `clamp(28px,calc(100vw / 10),60px)`)
- Update the CSS comment on line 333 to reflect the dynamic sizing

### Update Propagation

The HTML is generated server-side. A change to the text size preset takes effect on the next page load or WebSocket reconnect from the browser viewer. No live push mechanism is needed for this setting.

## Scope

### In scope
- New `BrowserFontSizePreset` enum with `cssClamp`/`mobileCssClamp` computed properties
- New `browserFontSizePreset` property on `NotchSettings` with UserDefaults persistence
- Segmented picker in Settings > Remote tab
- CSS injection in `BrowserServer.swift` HTML generation
- Update stale CSS comment

### Out of scope
- Text size control on the browser remote page itself (viewer-side control)
- Text size for Director mode
- Text size for the external display (NSPanel)
- Live-push of size changes without page reload
