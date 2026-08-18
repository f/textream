# Browser Remote Text Size Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a four-preset text size picker (SM/MD/LG/XL) for the browser remote viewer, controlled from the Mac app's Settings > Remote tab.

**Architecture:** New `BrowserFontSizePreset` enum in `NotchSettings.swift` with CSS clamp formulas as computed properties. Segmented picker in `SettingsView.swift` Remote tab. `BrowserServer.swift` reads the setting and injects the CSS values into the served HTML.

**Tech Stack:** Swift, SwiftUI, AppKit (NSPanel), embedded HTML/CSS/JS

**Spec:** `docs/superpowers/specs/2026-03-22-browser-remote-text-size-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `Textream/Textream/NotchSettings.swift` | Modify | Add `BrowserFontSizePreset` enum and `browserFontSizePreset` property |
| `Textream/Textream/SettingsView.swift` | Modify | Add segmented picker to Remote tab |
| `Textream/Textream/BrowserServer.swift` | Modify | Replace hardcoded font-size CSS with dynamic values from setting |

---

### Task 1: Add `BrowserFontSizePreset` enum to `NotchSettings.swift`

**Files:**
- Modify: `Textream/Textream/NotchSettings.swift:166` (insert new enum after `CueBrightness` closing brace at line 166, before `// MARK: - Overlay Mode` at line 168)

- [ ] **Step 1: Add the enum definition**

Insert after the closing `}` of `CueBrightness` at line 166, before `// MARK: - Overlay Mode` at line 168:

```swift
// MARK: - Browser Font Size Preset

enum BrowserFontSizePreset: String, CaseIterable, Identifiable {
    case sm, md, lg, xl

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sm: return "SM"
        case .md: return "MD"
        case .lg: return "LG"
        case .xl: return "XL"
        }
    }

    var cssClamp: String {
        switch self {
        case .sm: return "clamp(24px,calc(100vw / 22),48px)"
        case .md: return "clamp(32px,calc(100vw / 18),54px)"
        case .lg: return "clamp(40px,calc(100vw / 14),60px)"
        case .xl: return "clamp(48px,calc(100vw / 12),64px)"
        }
    }

    var mobileCssClamp: String {
        switch self {
        case .sm: return "clamp(18px,calc(100vw / 16),36px)"
        case .md: return "clamp(22px,calc(100vw / 13),42px)"
        case .lg: return "clamp(28px,calc(100vw / 10),48px)"
        case .xl: return "clamp(34px,calc(100vw / 8),56px)"
        }
    }
}
```

- [ ] **Step 2: Add persisted property to `NotchSettings`**

Add the property alongside the other browser settings (after `browserServerPort` around line 433-435):

```swift
var browserFontSizePreset: BrowserFontSizePreset {
    didSet { UserDefaults.standard.set(browserFontSizePreset.rawValue, forKey: "browserFontSizePreset") }
}
```

- [ ] **Step 3: Add initialization in `init()`**

Add after line 498 (`self.browserServerPort = ...`) and before line 499 (`self.directorModeEnabled = ...`):

```swift
self.browserFontSizePreset = BrowserFontSizePreset(rawValue: UserDefaults.standard.string(forKey: "browserFontSizePreset") ?? "") ?? .lg
```

- [ ] **Step 4: Build to verify no compile errors**

Run: `xcodebuild -project Textream/Textream.xcodeproj -scheme Textream -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Textream/Textream/NotchSettings.swift
git commit -m "feat: add BrowserFontSizePreset enum and setting"
```

---

### Task 2: Add segmented picker to Settings > Remote tab

**Files:**
- Modify: `Textream/Textream/SettingsView.swift:1073` (insert after the URL/copy-button row's closing background modifier, before the `DisclosureGroup("Advanced"...`)

- [ ] **Step 1: Add the picker UI**

Insert after the URL row block (after the `.background(RoundedRectangle...)` closing paren around line 1073) and before `DisclosureGroup("Advanced"` at line 1075:

```swift
VStack(alignment: .leading, spacing: 6) {
    Text("Remote Text Size")
        .font(.system(size: 13, weight: .medium))
    Picker("", selection: $settings.browserFontSizePreset) {
        ForEach(BrowserFontSizePreset.allCases) { preset in
            Text(preset.label).tag(preset)
        }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
}
```

- [ ] **Step 2: Build to verify no compile errors**

Run: `xcodebuild -project Textream/Textream.xcodeproj -scheme Textream -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Textream/Textream/SettingsView.swift
git commit -m "feat: add remote text size picker to Settings Remote tab"
```

---

### Task 3: Wire up dynamic CSS in `BrowserServer.swift`

**Files:**
- Modify: `Textream/Textream/BrowserServer.swift:333-335` (desktop font-size rule)
- Modify: `Textream/Textream/BrowserServer.swift:369-374` (mobile breakpoint)

- [ ] **Step 1: Replace desktop font-size CSS**

Find (around lines 333-335):
```
        /* Text: match ExternalDisplayView font sizing: max(48, min(96, width/14)) */
        #text-container{
          font-size:clamp(48px,calc(100vw / 14),96px);
```

Replace with:
```
        /* Text: browser remote font sizing from BrowserFontSizePreset */
        #text-container{
          font-size:\(NotchSettings.shared.browserFontSizePreset.cssClamp);
```

- [ ] **Step 2: Replace mobile breakpoint font-size CSS**

Find (around line 373):
```
          #text-container{font-size:clamp(28px,calc(100vw / 10),60px)}
```

Replace with:
```
          #text-container{font-size:\(NotchSettings.shared.browserFontSizePreset.mobileCssClamp)}
```

- [ ] **Step 3: Verify the string interpolation context**

Check that the HTML string containing these lines is already using Swift string interpolation (i.e., uses `\(...)` elsewhere). The BrowserServer HTML is built with string interpolation for colors and other dynamic values, so this pattern is consistent.

- [ ] **Step 4: Build to verify no compile errors**

Run: `xcodebuild -project Textream/Textream.xcodeproj -scheme Textream -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Textream/Textream/BrowserServer.swift
git commit -m "feat: use dynamic font size in browser remote HTML"
```

---

### Task 4: Manual verification

- [ ] **Step 1: Launch the app**

Run the app from Xcode (Cmd+R).

- [ ] **Step 2: Verify Settings UI**

Open Settings > Remote tab. Enable Remote Connection. Confirm the "Remote Text Size" segmented picker appears with SM / MD / LG / XL options below the URL row. Default should be LG (selected).

- [ ] **Step 3: Verify browser remote renders correctly**

Open the browser remote URL. Confirm text appears at the expected size. Change the preset in Settings, refresh the browser page, and confirm the text size changes.

- [ ] **Step 4: Verify each preset**

Cycle through all four presets (SM, MD, LG, XL), refreshing the browser each time. Confirm text scales from smallest (SM) to largest (XL).

- [ ] **Step 5: Verify mobile breakpoint**

Open browser dev tools, toggle responsive mode to a width under 768px. Confirm the mobile font sizes apply correctly for each preset.
