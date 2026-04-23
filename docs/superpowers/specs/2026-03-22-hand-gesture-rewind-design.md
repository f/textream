# Hand Gesture Rewind — Design Spec

## Problem

When presenting with Textream, the speaker sometimes needs to go back a few sentences in the script — to re-read a section, correct a mistake, or recover after going off-script. Currently there is no hands-free way to rewind. The speaker would have to walk to the laptop and tap the screen.

## Solution

Use the Mac's front-facing camera and Apple's Vision framework to detect a raised hand. While the hand is raised, the script rewinds continuously. Hand height controls rewind speed — higher hand = faster rewind. Lowering the hand resumes normal operation.

## Hand Detection Pipeline

A new `HandGestureController` class owns camera capture and Vision processing:

1. **AVCaptureSession** captures frames from the default front-facing camera at low resolution (~640x480) and low frame rate (~15fps)
2. Each frame is processed by **VNDetectHumanHandPoseRequest** which returns hand landmark coordinates
3. The **wrist Y-position** (0.0 = bottom of frame, 1.0 = top in Vision coordinates) is extracted and smoothed with a rolling average of the last 3-4 frames to reduce jitter
4. A **raise threshold** (wrist Y > 0.6) determines whether the hand is raised. Below this, the hand is in the speaker's lap or at their side and is ignored
5. If multiple hands are detected, use the one with the highest wrist Y-position
6. The controller publishes two observable values:
   - `isHandRaised: Bool`
   - `handHeight: Float` (0.0 = just above threshold, 1.0 = top of frame)

### Lifecycle

- Camera starts when a reading session begins — triggered by the overlay controller's `startReading()` flow, not tied to `SpeechRecognizer.start()` (since classic mode never calls it)
- Camera stops when the reading session ends
- Camera is NOT running when the app is idle
- If no camera is available (Mac Mini, Mac Pro, external displays without camera), the gesture feature is silently disabled

### Camera Selection

Uses the default front-facing camera. No settings UI for camera selection in this iteration.

### Camera Permission

If camera access is denied, the gesture feature is silently unavailable — no error is shown, no functionality is blocked. The rest of the app works normally. The `NSCameraUsageDescription` key in `Info.plist` provides the permission prompt text.

## Rewind Behavior

The scroll state lives in different places depending on the listening mode:
- **wordTracking:** `recognizedCharCount` on `SpeechRecognizer`
- **classic / silencePaused:** `timerWordProgress` on the overlay controller

The `HandGestureController` publishes `isHandRaised` and `handHeight`. The overlay controller observes these and dispatches rewind to the appropriate state.

### When hand is raised (`isHandRaised` becomes true):

**In wordTracking mode:**
1. Pause speech recognition — call a new `pauseForRewind()` method on `SpeechRecognizer` that stops the audio engine and recognition task without setting `isListening = false`
2. Start a rewind timer (every 0.25 seconds) that calls a new `rewindByWords(_ count: Int)` method on `SpeechRecognizer`, which moves `recognizedCharCount` backward by N words (finding previous space characters in `sourceText`) and updates `matchStartOffset` to match

**In classic / silencePaused mode:**
1. Pause the scroll timer
2. Start a rewind timer (every 0.25 seconds) that decrements `timerWordProgress` by N words

**Speed (all modes):** The `handHeight` value controls how many words per tick:
- Low hand (0.0–0.3): 1 word per tick (~4 words/sec)
- Mid hand (0.3–0.7): 2 words per tick (~8 words/sec)
- High hand (0.7–1.0): 4 words per tick (~16 words/sec)

Position is clamped to never go below 0.

### When hand is lowered (`isHandRaised` becomes false):

**In wordTracking mode:** Call a new `resumeAfterRewind()` method on `SpeechRecognizer` that sets `matchStartOffset = recognizedCharCount` and calls `beginRecognition()` to resume speech tracking from the new position.

**In classic / silencePaused mode:** Wait 1.5 seconds, then resume the scroll timer from the current `timerWordProgress` position.

### Visual Feedback

In wordTracking mode, MarqueeTextView observes `recognizedCharCount` — rewind scrolls backward automatically. In classic/silencePaused modes, the view observes `timerWordProgress` — same effect. No new UI components needed.

## File Organization

### New File

| File | Responsibility |
|------|---------------|
| `HandGestureController.swift` | AVCaptureSession setup, VNDetectHumanHandPoseRequest processing, wrist position smoothing, publishes `isHandRaised` and `handHeight` |

### Modified Files

| File | Change |
|------|--------|
| `SpeechRecognizer.swift` | Add `pauseForRewind()`, `rewindByWords(_:)`, and `resumeAfterRewind()` methods |
| `NotchOverlayController.swift` | Create and own `HandGestureController`, observe hand state, dispatch rewind to `SpeechRecognizer` or `timerWordProgress` depending on mode, manage rewind timer |
| `Info.plist` | Add `NSCameraUsageDescription` |

### Unchanged

MarqueeTextView, NotchSettings, ContentView, SettingsView, BrowserServer, ExternalDisplayController.

## Supported Listening Modes

The gesture rewind works in all three listening modes:
- **Word Tracking** (speech recognition) — rewinds `recognizedCharCount`
- **Classic** (constant auto-scroll) — rewinds `timerWordProgress`
- **Voice-Activated** (silence-paused auto-scroll) — rewinds `timerWordProgress`
