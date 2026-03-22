# Textream Productization Regression Checklist

## 1. Executable macOS Regression Matrix

### 1.1 Preparation

- Build baseline:
  `xcodebuild -project Textream/Textream.xcodeproj -scheme Textream -configuration Debug -sdk macosx CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build`
- Test baseline:
  `xcodebuild -project Textream/Textream.xcodeproj -scheme Textream -configuration Debug -sdk macosx CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test`
- Targeted smoke tests:
  `xcodebuild -project Textream/Textream.xcodeproj -scheme Textream -configuration Debug -sdk macosx CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:TextreamTests/TrackingGuardTests -only-testing:TextreamTests/WindowAnchorServiceTests -only-testing:TextreamTests/RemoteStateCompatibilityTests -only-testing:TextreamIntegrationTests/RemoteStateCompatibilityIntegrationTests test`
- Open `Settings -> QA & Debug`
- To inspect overlay state directly, enable `Show Debug Overlay`
- To collect decision traces, enable `Tracking Logs` and `Anchor Logs`
- Recommended attached-mode setup:
  1. A mainstream multi-window app such as Finder, Safari, or Chrome
  2. An external display or Sidecar target
  3. A script that includes normal reading, off-script narration, and bracket cues such as `[pause]`

### 1.2 Signals to Watch

- Tracking signal:
  `TRACK <state> | expected <word> | conf <level> | freeze <reason>`
- Anchor signal:
  `ANCHOR <AX|Quartz|Fallback> | AX on/off | <window> | <frame> | <message>`
- QA panel signal:
  `Live Tracking`, `Live Anchor`, `Recent QA Logs`

### 1.3 Scenario Matrix

| Scenario | Modes | Steps | Expected Behavior | Debug Signal |
| --- | --- | --- | --- | --- |
| Primary and secondary display switching | pinned / floating / attached / fullscreen | Start on the primary display, move main usage to the secondary display, and change fixed-display preferences | Overlay does not disappear or flicker; fullscreen reattaches to the intended screen | `Live Anchor` or display selection state updates coherently |
| External display unplug | attached / fullscreen / external | Attach to a window on the external display, then unplug the display; also test fullscreen while the external display is active | Attached falls back immediately; fullscreen exits cleanly or returns to the main display without leaving an orphaned panel | Anchor source changes to `Fallback` and logs record the display fallback |
| Fullscreen app target | attached | Select a fullscreen window, then enter and exit fullscreen | If stable geometry is unavailable, the overlay falls back or hides without visible jitter | Anchor source stays explainable across `AX`, `Quartz`, and `Fallback` |
| Stage Manager | attached | Switch active stages, collapse and expand side groups | When the target becomes unavailable the overlay falls back; when the target returns it reattaches | Logs show `window unavailable -> fallback -> relock` |
| Mission Control and Spaces | attached / pinned / floating | Switch Spaces quickly and move windows between Spaces via Mission Control | Overlay does not linger or flash in the wrong Space; attached mode falls back when needed | Logs and `Live Anchor` remain consistent |
| Accessibility not granted | attached | Revoke Accessibility and start attached mode | Attached mode can still open, but it must explain the fallback path | `AX Trusted = No`, source resolves to `Quartz` or `Fallback` |
| Accessibility granted while app is running | attached | Start attached mode, grant Accessibility in System Settings, then return | No restart required; geometry resolution upgrades automatically | Anchor source upgrades from `Quartz` to `AX` |
| Accessibility revoked while app is running | attached | Revoke Accessibility during an attached session | No crash; geometry resolution drops back cleanly | Anchor source downgrades from `AX` to `Quartz` or `Fallback` |
| AX success and Quartz fallback | attached | Use a multi-window app and repeatedly move and resize the selected window | The source remains visible and explainable; AX failure must not snap to the wrong sibling window | QA diagnostics clearly show `AX` or `Quartz` |
| Target window minimized, hidden, closed, or backgrounded | attached | Minimize, hide, close, or background the target app, then restore it | Overlay hides or falls back according to settings, and relocks when the window returns | Logs include unavailable, fallback, and relock transitions |
| Attached move, resize, and cross-screen drag | attached | Drag the target window, resize it, move it across displays, and pin it to screen edges | Overlay stays attached, including top and bottom movement, without drifting off-screen | Anchor frames update continuously and remain explainable |
| Repeated mode switching | all | Switch between pinned, floating, attached, and fullscreen during an active session | No leaked panels, stale hotkeys, or invalid anchor state | `Live Anchor` resets to inactive outside attached mode |
| On-script reading | tracking | Read the script normally | State stays in `Tracking`, `expectedWord` advances steadily | `freeze None` with advancement detail |
| Off-script narration | tracking | Read normally, then speak off-script for two seconds | State moves into `Checking Script` or `Off Script`, and advancement freezes | Freeze reason reports low match or off-script audio |
| Hold to Ignore and Aside | tracking | Hold `Fn`, double-tap `Option`, then resume | Freeze occurs within 100 ms; relock happens within about one second | Freeze reason reports manual aside or recovery pending |
| `[pause]`, skipped words, repeated words, and paraphrasing | tracking | Use a script that includes cue tokens and spoken deviations | Weak matches do not push the script forward blindly; relocking remains possible | QA detail reports low-score and insufficient-match cases |
| `[wave]` and other bracket cues | tracking | Insert `[wave]` or `[smile]` into the script but only speak the main text | Bracket cues remain visual annotations and do not block advancement or completion | `Expected` skips directly to the next spoken token |
| HUD disabled or all modules removed | all overlay modes | Disable Persistent HUD or clear all HUD modules | No empty top spacer remains in preview or the live overlay | HUD strip is not rendered when the item list is empty |
| Teleprompter settings by mode | fullscreen / attached / floating | Inspect the Teleprompter settings page in each mode | Each mode only shows relevant controls | Mode-specific controls match the active overlay mode |
| Browser legacy client compatibility | browser remote | Decode a payload using only the old field set | Older clients ignore the new fields and stay connected | `RemoteStateCompatibilityTests` passes |
| Director legacy client compatibility | director | Decode a payload using only the old field set | Older clients ignore the new fields and stay connected | `RemoteStateCompatibilityTests` passes |

## 2. QA Panel and Logging Controls

### 2.1 Entry Point

- `Settings -> QA & Debug`

### 2.2 Switches

- `Show Debug Overlay`
  Shows tracking and anchor labels directly inside the teleprompter overlay
- `Tracking Logs`
  Writes `TrackingGuard` state changes, freeze reasons, and recovery phases into the QA log stream
- `Anchor Logs`
  Writes `WindowAnchorService` decisions for `AX`, `Quartz`, and `Fallback` into the QA log stream

### 2.3 Reading the QA Surface

- `Live Tracking`
  Confirms `state`, `expectedWord`, `confidence`, `freeze reason`, and detail
- `Live Anchor`
  Confirms whether the app is using `AX`, `Quartz`, or `Fallback`, and whether Accessibility is trusted
- `Recent QA Logs`
  Preserves decision history across transitions so failures can be reconstructed without Xcode attached

## 3. Issues Found and Fixes Applied

### Issue 1: Attached fallback was tied to a stale launch-time screen

- Reproduction:
  1. Start attached mode on a window that lives on an external display
  2. Minimize the target window or unplug the display
- Expected:
  The overlay falls back to the currently visible display corner
- Actual before fix:
  Fallback used the original launch-time screen, which could make the overlay appear to disappear after display topology changes
- Fix:
  Resolve fallback from the panel's current screen first, then fall back to the main screen
- Current status:
  Code path is fixed; real hardware verification is still recommended for unplug plus Space transitions

### Issue 2: AX window matching relied too heavily on title equality

- Reproduction:
  1. Open multiple windows from the same app with identical or missing titles
  2. Attach to one of them
  3. Move or resize the intended target
- Expected:
  AX matching should choose the window whose geometry is closest to the Quartz candidate
- Actual before fix:
  The first title match could win, causing attachment to the wrong sibling window
- Fix:
  Use a combined score of title preference plus geometric proximity to the Quartz bounds
- Current status:
  Risk is much lower in common multi-window apps, but Finder, Safari, and Chrome should still be checked manually

### Issue 3: Tracking freeze reasons were not visible enough for QA

- Reproduction:
  1. Speak off-script for two seconds
  2. Or hold `Fn` to trigger hold-to-ignore
- Expected:
  QA should be able to see the current state, expected word, confidence, and freeze reason directly
- Actual before fix:
  The overlay only surfaced a generic state and made it hard to tell intentional freeze from a mismatch
- Fix:
  Added `decisionReason` and `debugSummary` to `TrackingGuard`, and surfaced them in QA and overlay debug views
- Current status:
  Failures are now diagnosable without attaching Xcode

### Issue 4: Remote protocol expansion lacked explicit compatibility coverage

- Reproduction:
  1. Decode Browser or Director payloads with an old client that only knows the legacy fields
  2. Feed it a payload with the new tracking fields
- Expected:
  Older clients ignore the new fields and remain connected
- Actual before fix:
  The design was intended to be backward-compatible, but the assumption was not enforced automatically
- Fix:
  Added `RemoteStateCompatibilityTests` to verify both old-client decoding and new-payload compatibility
- Current status:
  Protocol compatibility now has automated regression coverage

### Issue 5: Bracket cues such as `[wave]` could block strict tracking and completion

- Reproduction:
  1. Use `hello [wave] there`
  2. Speak only `hello there`
  3. Or end the page with a bracket cue
- Expected:
  Bracket cues stay visual and do not become required spoken tokens
- Actual before fix:
  The normalized cue text was treated as a required tracking token, which could block `expectedWord` and completion
- Fix:
  Treat bracket cues as styled annotations that auto-skip in the tracking token stream
- Current status:
  Covered by `TrackingGuardTests`, including the trailing-cue completion case

### Issue 6: Persistent HUD reserved empty space even when nothing was shown

- Reproduction:
  1. Disable `Persistent HUD`
  2. Or clear all HUD modules
  3. Open preview, notch, floating, or external teleprompter
- Expected:
  No empty spacer should remain at the top of the overlay
- Actual before fix:
  Preview and live overlays both kept an empty vertical gap
- Fix:
  Skip HUD strip rendering entirely when `items.isEmpty`; keep QA overlay independent
- Current status:
  Rendering paths are unified; manual confirmation is still recommended for preview versus live parity

### Issue 7: Teleprompter settings mixed controls from unrelated modes

- Reproduction:
  1. Switch to `Fullscreen`
  2. Open `Settings -> Teleprompter`
  3. Check whether floating-only controls such as `Pointer Follow` still appear
- Expected:
  The settings page should only show controls relevant to the active mode
- Actual before fix:
  Floating-specific controls appeared globally and created the wrong mental model
- Fix:
  Moved `Pointer Follow` back into the floating-only section; attached mode now focuses on target window, corner, margin, and size; fullscreen focuses on display and exit behavior
- Current status:
  The information architecture is much clearer, though smaller window heights should still be checked manually

### Issue 8: Attached anchoring could pick the screen corner instead of the window corner near edges

- Reproduction:
  1. Drag the target window to a display edge or across display boundaries
  2. Switch between all four attachment corners
  3. Observe the attached overlay position
- Expected:
  Screen selection and clamping should follow the target window's interior corner, not the whole display edge
- Actual before fix:
  Corner math could resolve against the wrong display and push the overlay off-screen or away from the top or bottom edge
- Fix:
  Use interior probe points for screen selection and keep visible-frame clamping
- Current status:
  `WindowAnchorServiceTests` now covers top and bottom clamping; real multi-display and Stage Manager behavior still needs manual review

## 4. Regression Conclusion and Remaining Risks

### 4.1 Current Conclusion

- The P0, P1, and P2 work now has the expected productization support:
  - executable regression matrix
  - in-app QA panel
  - overlay debug labels
  - tracking and anchor log streams
  - automated Browser and Director compatibility coverage
- The project is now in a good state for manual regression and issue closure rather than further feature expansion
- Code-level validation already completed:
  - unsigned Debug build succeeds
  - `TrackingGuardTests` passes
  - `WindowAnchorServiceTests` passes
  - `RemoteStateCompatibilityTests` and `RemoteStateCompatibilityIntegrationTests` pass

### 4.2 Remaining Risks

- Fullscreen apps, Stage Manager, Mission Control, and Spaces still depend heavily on platform window-visibility behavior and cannot be covered fully by unit tests alone
- External display unplug behavior is fixed in code, but still benefits from real hardware validation across unplug timing and Space transitions
- `AX -> Quartz -> Fallback` is now observable and explainable, but some third-party apps may still expose unstable window metadata
- The settings window and preview panel should still be checked visually on smaller screens to ensure layout remains readable

### 4.3 Suggested Exit Criteria

- Every scenario in the matrix has been exercised at least once manually
- `Recent QA Logs` shows no unexplained source thrash or state thrash
- Remaining attached-mode issues are limited to platform constraints, not unresolved engineering bugs
