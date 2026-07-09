# Hand Gesture Rewind Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add hands-free script rewind via raised hand detection using the Mac's front-facing camera and Apple Vision framework.

**Architecture:** A new `HandGestureController` owns camera capture and Vision hand pose detection, publishing `isHandRaised` and `handHeight`. The overlay views observe these values and dispatch rewind to the appropriate scroll state (`recognizedCharCount` for wordTracking, `timerWordProgress` for classic/silencePaused). New methods on `SpeechRecognizer` handle pause/rewind/resume for wordTracking mode.

**Tech Stack:** Swift, AVFoundation (camera capture), Vision framework (VNDetectHumanHandPoseRequest)

**Spec:** `docs/superpowers/specs/2026-03-22-hand-gesture-rewind-design.md`

**Note:** This project has no test target. All Swift files live in `Textream/Textream/`. The project builds via `xcodebuild` from `Textream/Textream.xcodeproj`. Use `CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""` when building.

**Important — Adding files to Xcode project:** This is a pure Xcode project (no SPM). New `.swift` files are auto-discovered by the build system. Bundle resources and entitlements changes need manual verification.

---

## File Map

### New Files

| File | Responsibility |
|------|---------------|
| `Textream/Textream/HandGestureController.swift` | AVCaptureSession setup, VNDetectHumanHandPoseRequest processing, wrist Y smoothing, publishes `isHandRaised` and `handHeight` |

### Modified Files

| File | Change |
|------|--------|
| `Textream/Textream/SpeechRecognizer.swift` | Add `pauseForRewind()`, `rewindByWords(_:)`, `resumeAfterRewind()` methods |
| `Textream/Textream/NotchOverlayController.swift` | Create `HandGestureController`, observe hand state in both overlay views, manage rewind timer, dispatch to correct scroll state per mode |
| `Textream/Info.plist` | Add `NSCameraUsageDescription` |
| `Textream/Textream/Textream.entitlements` | Add `com.apple.security.device.camera` |

---

### Task 1: Camera Permission and Entitlements

**Files:**
- Modify: `Textream/Info.plist`
- Modify: `Textream/Textream/Textream.entitlements`

- [ ] **Step 1: Add camera usage description to Info.plist**

Add the following key/value pair inside the `<dict>` in `Textream/Info.plist`, after the existing `NSServices` block:

```xml
<key>NSCameraUsageDescription</key>
<string>Textream uses the camera to detect hand gestures for hands-free script control.</string>
```

- [ ] **Step 2: Add camera entitlement**

Add the following key/value pair inside the `<dict>` in `Textream/Textream/Textream.entitlements`, after the existing `com.apple.security.device.audio-input` entry:

```xml
<key>com.apple.security.device.camera</key>
<true/>
```

- [ ] **Step 3: Verify build**

```bash
cd Textream && xcodebuild -scheme Textream -configuration Debug CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Textream/Info.plist Textream/Textream/Textream.entitlements
git commit -m "feat: add camera permission and entitlement for hand gesture rewind"
```

---

### Task 2: HandGestureController

**Files:**
- Create: `Textream/Textream/HandGestureController.swift`

This is the core camera + Vision processing class. It owns the capture session, runs hand pose detection on each frame, smooths the wrist position, and publishes state.

- [ ] **Step 1: Implement HandGestureController**

```swift
import AVFoundation
import Vision
import AppKit

@Observable
class HandGestureController: NSObject {
    var isHandRaised: Bool = false
    var handHeight: Float = 0.0  // 0.0 = just above threshold, 1.0 = top of frame

    private var captureSession: AVCaptureSession?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let processingQueue = DispatchQueue(label: "com.textream.handgesture", qos: .userInteractive)
    private let handPoseRequest = VNDetectHumanHandPoseRequest()

    private let raiseThreshold: Float = 0.6  // wrist Y must exceed this to count as raised
    private var recentWristY: [Float] = []   // rolling buffer for smoothing
    private let smoothingWindow = 4

    private var isRunning = false

    override init() {
        super.init()
        handPoseRequest.maximumHandCount = 2
    }

    func start() {
        guard !isRunning else { return }

        // Check camera permission
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    DispatchQueue.main.async { self?.setupAndStart() }
                }
            }
        default:
            // Permission denied or restricted — silently disable
            return
        }
    }

    func stop() {
        guard isRunning else { return }
        captureSession?.stopRunning()
        isRunning = false
        isHandRaised = false
        handHeight = 0.0
        recentWristY = []
    }

    private func setupAndStart() {
        let session = AVCaptureSession()
        session.sessionPreset = .low  // ~640x480, minimal resource usage

        // Find front-facing camera
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video) else {
            // No camera available — silently disable
            return
        }

        guard let input = try? AVCaptureDeviceInput(device: camera) else { return }
        guard session.canAddInput(input) else { return }
        session.addInput(input)

        videoOutput.setSampleBufferDelegate(self, queue: processingQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(videoOutput) else { return }
        session.addOutput(videoOutput)

        // Limit frame rate to ~15fps to save CPU
        if let connection = videoOutput.connection(with: .video) {
            connection.isEnabled = true
        }
        try? camera.lockForConfiguration()
        camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 15)
        camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 15)
        camera.unlockForConfiguration()

        captureSession = session

        processingQueue.async {
            session.startRunning()
        }
        isRunning = true
    }
}

extension HandGestureController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([handPoseRequest])

        guard let results = handPoseRequest.results, !results.isEmpty else {
            DispatchQueue.main.async {
                self.updateWristPosition(nil)
            }
            return
        }

        // Find the hand with the highest wrist Y
        var highestWristY: Float = 0
        for hand in results {
            if let wrist = try? hand.recognizedPoint(.wrist),
               wrist.confidence > 0.3 {
                let y = Float(wrist.location.y)  // Vision coords: 0=bottom, 1=top
                if y > highestWristY {
                    highestWristY = y
                }
            }
        }

        DispatchQueue.main.async {
            self.updateWristPosition(highestWristY > 0 ? highestWristY : nil)
        }
    }

    private func updateWristPosition(_ wristY: Float?) {
        guard let y = wristY else {
            // No hand detected — decay smoothly
            recentWristY = []
            isHandRaised = false
            handHeight = 0.0
            return
        }

        // Smooth with rolling average
        recentWristY.append(y)
        if recentWristY.count > smoothingWindow {
            recentWristY.removeFirst()
        }
        let smoothed = recentWristY.reduce(0, +) / Float(recentWristY.count)

        if smoothed > raiseThreshold {
            isHandRaised = true
            // Map threshold..1.0 → 0.0..1.0
            handHeight = min(1.0, (smoothed - raiseThreshold) / (1.0 - raiseThreshold))
        } else {
            isHandRaised = false
            handHeight = 0.0
        }
    }
}
```

- [ ] **Step 2: Verify build**

```bash
cd Textream && xcodebuild -scheme Textream -configuration Debug CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Textream/Textream/HandGestureController.swift
git commit -m "feat: add HandGestureController with Vision hand pose detection"
```

---

### Task 3: SpeechRecognizer Rewind Methods

**Files:**
- Modify: `Textream/Textream/SpeechRecognizer.swift`

Add three new public methods that the overlay views will call during hand gesture rewind. These methods encapsulate access to the private `matchStartOffset`, `sourceText`, `cleanupRecognition()`, and `beginRecognition()`.

- [ ] **Step 1: Add pauseForRewind()**

Add the following method after `resume()` (after line 210 in SpeechRecognizer.swift):

```swift
    /// Pause speech recognition for gesture rewind without changing isListening state.
    func pauseForRewind() {
        cleanupRecognition()
    }
```

- [ ] **Step 2: Add rewindByWords(\_:)**

Add directly after `pauseForRewind()`:

```swift
    /// Move recognizedCharCount backward by N words. Used during gesture rewind.
    func rewindByWords(_ count: Int) {
        // Work with the string as an array for O(1) indexing
        let chars = Array(sourceText)
        var remaining = count
        var offset = recognizedCharCount

        while remaining > 0 && offset > 0 {
            // Skip any spaces at current position
            while offset > 0 && chars[offset - 1] == " " {
                offset -= 1
            }
            // Skip to start of current word
            while offset > 0 && chars[offset - 1] != " " {
                offset -= 1
            }
            remaining -= 1
        }

        recognizedCharCount = max(0, offset)
        matchStartOffset = recognizedCharCount
    }
```

- [ ] **Step 3: Add resumeAfterRewind()**

Add directly after `rewindByWords(_:)`:

```swift
    /// Resume speech recognition after gesture rewind from current position.
    func resumeAfterRewind() {
        matchStartOffset = recognizedCharCount
        retryCount = 0
        beginRecognition()
    }
```

- [ ] **Step 4: Verify build**

```bash
cd Textream && xcodebuild -scheme Textream -configuration Debug CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Textream/Textream/SpeechRecognizer.swift
git commit -m "feat: add pauseForRewind, rewindByWords, resumeAfterRewind to SpeechRecognizer"
```

---

### Task 4: Integrate HandGestureController into Overlay Views

**Files:**
- Modify: `Textream/Textream/NotchOverlayController.swift`

This is the integration task. The `HandGestureController` needs to be:
1. Created and owned by `NotchOverlayController`
2. Started/stopped with reading sessions
3. Observed by both `NotchOverlayView` and `FloatingOverlayView` to drive rewind

**Key context:** `timerWordProgress` is `@State private` on both `NotchOverlayView` (line 625) and `FloatingOverlayView` (line 1153). The rewind logic for classic/silencePaused must live inside these views since they own the state. The `HandGestureController` is passed to both views and observed via `onChange(of:)`.

- [ ] **Step 1: Add HandGestureController to NotchOverlayController**

In the `NotchOverlayController` class (around line 47), add a property:

```swift
let handGestureController = HandGestureController()
```

- [ ] **Step 2: Start/stop camera with reading sessions**

Find `show(text:hasNextPage:onComplete:)` (line 62) — after the existing `speechRecognizer.start(with:)` call (line 118), add:

```swift
handGestureController.start()
```

Find `updateContent(text:hasNextPage:)` (line 122) — similarly add `handGestureController.start()` after the recognizer start.

Find `dismiss()` (line 376) and `forceClose()` (line 411) — add to both:

```swift
handGestureController.stop()
```

- [ ] **Step 3: Pass HandGestureController to NotchOverlayView**

The `NotchOverlayView` needs access to `handGestureController`. Add it as a parameter to the view's init. Find where `NotchOverlayView` is created in `NotchOverlayController` and pass `handGestureController`.

In `NotchOverlayView`, add a property:

```swift
var handGesture: HandGestureController
```

- [ ] **Step 4: Add rewind logic to NotchOverlayView**

Add a rewind timer state and handler to `NotchOverlayView`. Add these properties near the other `@State` declarations (around line 625):

```swift
@State private var rewindTimer: Timer?
@State private var resumeDelay: DispatchWorkItem?
```

Add a helper to compute words-per-tick from hand height:

```swift
private func rewindWordsPerTick(handHeight: Float) -> Int {
    if handHeight < 0.3 { return 1 }
    if handHeight < 0.7 { return 2 }
    return 4
}
```

Add `onChange` handlers in the view body (inside the main container, near the existing `onChange` handlers):

```swift
.onChange(of: handGesture.isHandRaised) { _, raised in
    if raised {
        // Cancel any pending resume delay
        resumeDelay?.cancel()
        resumeDelay = nil

        // Pause current mode
        switch listeningMode {
        case .wordTracking:
            speechRecognizer.pauseForRewind()
        case .classic:
            isPaused = true
        case .silencePaused:
            speechRecognizer.pauseForRewind()
            isPaused = true  // also pause the scroll timer
        }

        // Start rewind timer
        rewindTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            let words = rewindWordsPerTick(handHeight: handGesture.handHeight)
            switch listeningMode {
            case .wordTracking:
                speechRecognizer.rewindByWords(words)
            case .classic, .silencePaused:
                timerWordProgress = max(0, timerWordProgress - Double(words))
            }
        }
    } else {
        // Stop rewind timer
        rewindTimer?.invalidate()
        rewindTimer = nil

        // Resume based on mode
        switch listeningMode {
        case .wordTracking:
            speechRecognizer.resumeAfterRewind()
        case .classic:
            let work = DispatchWorkItem { isPaused = false }
            resumeDelay = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        case .silencePaused:
            speechRecognizer.resumeAfterRewind()
            let work = DispatchWorkItem { isPaused = false }
            resumeDelay = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }
}
.onDisappear {
    rewindTimer?.invalidate()
    rewindTimer = nil
    resumeDelay?.cancel()
    resumeDelay = nil
}
```

- [ ] **Step 5: Repeat for FloatingOverlayView**

Apply the same changes to `FloatingOverlayView` (starts around line 1136):
- Add `handGesture: HandGestureController` property
- Add `rewindTimer`, `resumeDelay` state
- Add `rewindWordsPerTick` helper
- Add the same `onChange(of: handGesture.isHandRaised)` handler with `.onDisappear` cleanup
- Pass `handGestureController` from where `FloatingOverlayView` is created

**Finding all view instantiation sites:** Search `NotchOverlayController.swift` for `NotchOverlayView(` and `FloatingOverlayView(` to find every place these views are created. Each call site must pass the `handGestureController`. There are typically 1-2 sites per view (in `showPinned`, `showFollowCursor`, `showFloating`, etc.).

**Note:** Fullscreen mode uses `ExternalDisplayView` which is not addressed in this plan — gesture rewind in fullscreen is a future enhancement.

- [ ] **Step 6: Verify build**

```bash
cd Textream && xcodebuild -scheme Textream -configuration Debug CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 7: Build and launch the app**

```bash
cd Textream && xcodebuild -scheme Textream -configuration Debug CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build 2>&1 | tail -5
```

Then launch the app and test:
1. Load a script and start reading in Word Tracking mode
2. Raise your hand above shoulder height — script should start rewinding
3. Raise hand higher — rewind should speed up
4. Lower hand — speech recognition should resume from new position
5. Switch to Classic mode, start auto-scroll, raise hand — should rewind `timerWordProgress`
6. Lower hand — 1.5s pause, then auto-scroll resumes

- [ ] **Step 8: Commit**

```bash
git add Textream/Textream/NotchOverlayController.swift
git commit -m "feat: integrate hand gesture rewind into overlay views

Start/stop camera with reading sessions. Both NotchOverlayView
and FloatingOverlayView observe HandGestureController to drive
rewind in all three listening modes."
```
