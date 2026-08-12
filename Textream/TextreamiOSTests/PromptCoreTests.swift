@preconcurrency import AVFoundation
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import TextreamiOS

@MainActor
private final class IdleTimerControllerSpy: IdleTimerControlling {
    var isIdleTimerDisabled: Bool {
        didSet { updates.append(isIdleTimerDisabled) }
    }
    private(set) var updates: [Bool] = []

    init(isIdleTimerDisabled: Bool = false) {
        self.isIdleTimerDisabled = isIdleTimerDisabled
    }
}

@MainActor
private final class EditorBindingHarness {
    var text: String
    var isFocused: Bool

    init(text: String, isFocused: Bool) {
        self.text = text
        self.isFocused = isFocused
    }

    var editor: BracketHighlightingTextEditor {
        BracketHighlightingTextEditor(
            text: Binding(
                get: { [unowned self] in self.text },
                set: { [unowned self] in self.text = $0 }
            ),
            isFocused: Binding(
                get: { [unowned self] in self.isFocused },
                set: { [unowned self] in self.isFocused = $0 }
            ),
            accessibilityLabel: "Script",
            accessibilityIdentifier: "scriptEditor"
        )
    }
}

@MainActor
private final class FirstResponderTextViewSpy: UITextView {
    private var firstResponderState = false
    private(set) var becomeFirstResponderCallCount = 0
    private(set) var resignFirstResponderCallCount = 0

    override var isFirstResponder: Bool { firstResponderState }

    override func becomeFirstResponder() -> Bool {
        becomeFirstResponderCallCount += 1
        firstResponderState = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        resignFirstResponderCallCount += 1
        firstResponderState = false
        return true
    }

    func assumeFirstResponder() {
        firstResponderState = true
    }
}

@Suite("Prompt core")
struct PromptCoreTests {
    @MainActor
    @Test
    func scriptEditorKeepsFocusAndSelectionAcrossEveryTypingBindingEcho() {
        let harness = EditorBindingHarness(text: "Start", isFocused: true)
        let coordinator = BracketHighlightingTextEditor.Coordinator(parent: harness.editor)
        let textView = FirstResponderTextViewSpy()
        textView.text = harness.text
        textView.selectedRange = NSRange(location: 5, length: 0)
        textView.assumeFirstResponder()
        let baselineBecomeCalls = textView.becomeFirstResponderCallCount
        let baselineResignCalls = textView.resignFirstResponderCallCount

        for character in " [cue] typing" {
            let insertionPoint = textView.selectedRange.location
            let mutableText = NSMutableString(string: textView.text)
            mutableText.insert(String(character), at: insertionPoint)
            textView.text = mutableText as String
            textView.selectedRange = NSRange(location: insertionPoint + 1, length: 0)

            // UIKit reports the edit, then SwiftUI echoes the new binding back
            // through updateUIView. Neither phase may resign/refocus the editor
            // or move the insertion point.
            coordinator.textViewDidChange(textView)
            coordinator.parent = harness.editor
            coordinator.update(textView, force: false)

            #expect(harness.text == textView.text)
            #expect(textView.isFirstResponder)
            #expect(textView.selectedRange == NSRange(location: insertionPoint + 1, length: 0))
        }

        #expect(textView.becomeFirstResponderCallCount == baselineBecomeCalls)
        #expect(textView.resignFirstResponderCallCount == baselineResignCalls)
    }

    @MainActor
    @Test
    func scriptEditorExternalBindingUpdatePreservesAValidSelectionAndFocus() {
        let harness = EditorBindingHarness(text: "A longer script", isFocused: true)
        let coordinator = BracketHighlightingTextEditor.Coordinator(parent: harness.editor)
        let textView = FirstResponderTextViewSpy()
        textView.text = harness.text
        textView.selectedRange = NSRange(location: 2, length: 6)
        textView.assumeFirstResponder()
        let baselineBecomeCalls = textView.becomeFirstResponderCallCount
        let baselineResignCalls = textView.resignFirstResponderCallCount

        harness.text = "Short"
        coordinator.parent = harness.editor
        coordinator.update(textView, force: false)

        #expect(textView.text == "Short")
        #expect(textView.selectedRange == NSRange(location: 2, length: 3))
        #expect(textView.isFirstResponder)
        #expect(textView.becomeFirstResponderCallCount == baselineBecomeCalls)
        #expect(textView.resignFirstResponderCallCount == baselineResignCalls)
    }

    @MainActor
    @Test
    func scriptEditorDoesNotOverwriteMarkedTextComposition() {
        let harness = EditorBindingHarness(text: "Hello", isFocused: true)
        let coordinator = BracketHighlightingTextEditor.Coordinator(parent: harness.editor)
        let textView = FirstResponderTextViewSpy()
        textView.text = harness.text
        textView.selectedRange = NSRange(location: 5, length: 0)
        textView.assumeFirstResponder()
        textView.setMarkedText("世界", selectedRange: NSRange(location: 2, length: 0))
        let baselineResignCalls = textView.resignFirstResponderCallCount

        let composingText = textView.text
        let composingSelection = textView.selectedRange
        #expect(textView.markedTextRange != nil)

        harness.text = "An external model refresh"
        coordinator.parent = harness.editor
        coordinator.update(textView, force: false)

        #expect(textView.text == composingText)
        #expect(textView.selectedRange == composingSelection)
        #expect(textView.markedTextRange != nil)
        #expect(textView.isFirstResponder)
        #expect(textView.resignFirstResponderCallCount == baselineResignCalls)
    }

    @MainActor
    @Test
    func scriptEditorResignsOnlyAfterExplicitFocusDismissal() {
        let harness = EditorBindingHarness(text: "Script", isFocused: true)
        let coordinator = BracketHighlightingTextEditor.Coordinator(parent: harness.editor)
        let textView = FirstResponderTextViewSpy()
        textView.text = harness.text
        textView.assumeFirstResponder()
        let baselineResignCalls = textView.resignFirstResponderCallCount

        coordinator.update(textView, force: false)
        #expect(textView.isFirstResponder)
        #expect(textView.resignFirstResponderCallCount == baselineResignCalls)

        harness.isFocused = false
        coordinator.parent = harness.editor
        coordinator.update(textView, force: false)

        #expect(!textView.isFirstResponder)
        #expect(textView.resignFirstResponderCallCount == baselineResignCalls + 1)
    }

    @MainActor
    @Test
    func switchingFromCompactToExpandedEditorTransfersFocusDeliberately() {
        let compact = EditorBindingHarness(text: "Shared script", isFocused: true)
        let compactCoordinator = BracketHighlightingTextEditor.Coordinator(parent: compact.editor)
        let compactTextView = FirstResponderTextViewSpy()
        compactTextView.text = compact.text
        compactTextView.assumeFirstResponder()
        let compactBaselineResignCalls = compactTextView.resignFirstResponderCallCount

        // RootView explicitly dismisses the compact editor before presenting
        // the full-screen editor.
        compact.isFocused = false
        compactCoordinator.parent = compact.editor
        compactCoordinator.update(compactTextView, force: false)
        #expect(!compactTextView.isFirstResponder)
        #expect(compactTextView.resignFirstResponderCallCount == compactBaselineResignCalls + 1)

        let expanded = EditorBindingHarness(text: compact.text, isFocused: true)
        let expandedCoordinator = BracketHighlightingTextEditor.Coordinator(parent: expanded.editor)
        let expandedTextView = FirstResponderTextViewSpy()
        expandedTextView.text = expanded.text
        expandedTextView.selectedRange = NSRange(
            location: (expanded.text as NSString).length,
            length: 0
        )
        expandedTextView.assumeFirstResponder()
        let expandedBaselineBecomeCalls = expandedTextView.becomeFirstResponderCallCount
        let expandedBaselineResignCalls = expandedTextView.resignFirstResponderCallCount

        expandedCoordinator.update(expandedTextView, force: false)
        #expect(expandedTextView.isFirstResponder)
        #expect(expandedTextView.selectedRange.location == (expanded.text as NSString).length)
        #expect(expandedTextView.becomeFirstResponderCallCount == expandedBaselineBecomeCalls)
        #expect(expandedTextView.resignFirstResponderCallCount == expandedBaselineResignCalls)
    }

    @Test
    func cameraRotationStateTracksPreviewAndCaptureAnglesIndependently() {
        var state = CameraRotationState()

        #expect(state.consumePreviewAngle(90) == 90)
        #expect(state.consumeCaptureAngle(180) == 180)
        #expect(state.previewAngle == 90)
        #expect(state.captureAngle == 180)

        #expect(state.consumePreviewAngle(90.4) == nil)
        #expect(state.consumeCaptureAngle(180.4) == nil)
        #expect(state.consumePreviewAngle(0) == 0)
        #expect(state.previewAngle == 0)
        #expect(state.captureAngle == 180)

        state.reset()
        #expect(state.consumePreviewAngle(0) == 0)
        #expect(state.consumeCaptureAngle(0) == 0)
    }

    @Test
    func captureRotationDoesNotChangeAnActiveMovieConnection() {
        #expect(CaptureController.shouldApplyCaptureRotationImmediately(isRecording: false))
        #expect(!CaptureController.shouldApplyCaptureRotationImmediately(isRecording: true))
    }

    @Test
    func recordingStateOwnsAnAdditionalIdleTimerLeaseOnlyWhileCapturing() {
        #expect(!CaptureRecordingState.idle.preventsIdleSleep)
        #expect(CaptureRecordingState.starting.preventsIdleSleep)
        #expect(CaptureRecordingState.recording.preventsIdleSleep)
        #expect(!CaptureRecordingState.stopping.preventsIdleSleep)
        #expect(!CaptureRecordingState.saving.preventsIdleSleep)
    }

    @Test
    func recordControlMorphsInPlaceAcrossTheFullCaptureLifecycle() {
        let idle = RecordControlPresentation(
            recordingState: .idle,
            canStartRecording: true
        )
        let starting = RecordControlPresentation(
            recordingState: .starting,
            canStartRecording: false
        )
        let recording = RecordControlPresentation(
            recordingState: .recording,
            canStartRecording: false
        )
        let stopping = RecordControlPresentation(
            recordingState: .stopping,
            canStartRecording: false
        )
        let saving = RecordControlPresentation(
            recordingState: .saving,
            canStartRecording: false
        )

        // The same mounted control changes only its inner presentation: a
        // record dot before capture, a stop square while capture is active,
        // then a record dot again while saving and once idle.
        #expect(!idle.showsStopShape)
        #expect(!starting.showsStopShape)
        #expect(recording.showsStopShape)
        #expect(stopping.showsStopShape)
        #expect(!saving.showsStopShape)

        #expect(!idle.showsActivity)
        #expect(starting.showsActivity)
        #expect(!recording.showsActivity)
        #expect(stopping.showsActivity)
        #expect(saving.showsActivity)

        #expect(idle.isEnabled)
        #expect(starting.isEnabled)
        #expect(recording.isEnabled)
        #expect(!stopping.isEnabled)
        #expect(!saving.isEnabled)
        #expect(recording.accessibilityLabel == "Stop recording")
        #expect(stopping.accessibilityLabel == "Finishing recording")
        #expect(saving.accessibilityLabel == "Saving recording")
        #expect(saving.accessibilityValue == "Saving to Photos")
    }

    @Test
    func unavailableIdleRecordControlDoesNotAcceptTouches() {
        let presentation = RecordControlPresentation(
            recordingState: .idle,
            canStartRecording: false
        )

        #expect(!presentation.isEnabled)
        #expect(!presentation.showsStopShape)
        #expect(presentation.accessibilityLabel == "Start recording")
        #expect(presentation.accessibilityValue == "Unavailable")
    }

    @MainActor
    @Test
    func promptSessionIdleTimerOverrideIsScopedAndRestoresThePreviousValue() {
        let spy = IdleTimerControllerSpy()
        let coordinator = PromptSessionIdleTimerCoordinator(controller: spy)
        let owner = UUID()

        coordinator.acquire(owner: owner)
        coordinator.acquire(owner: owner)
        coordinator.release(owner: owner)
        coordinator.release(owner: owner)

        #expect(spy.updates == [true, false])
        #expect(!spy.isIdleTimerDisabled)

        let preDisabledSpy = IdleTimerControllerSpy(isIdleTimerDisabled: true)
        let secondCoordinator = PromptSessionIdleTimerCoordinator(controller: preDisabledSpy)
        let secondOwner = UUID()
        secondCoordinator.acquire(owner: secondOwner)
        secondCoordinator.release(owner: secondOwner)
        #expect(preDisabledSpy.updates.isEmpty)
        #expect(preDisabledSpy.isIdleTimerDisabled)
    }

    @MainActor
    @Test
    func promptSessionIdleTimerWaitsForEveryOpenPrompterToClose() {
        let spy = IdleTimerControllerSpy()
        let coordinator = PromptSessionIdleTimerCoordinator(controller: spy)
        let firstScene = UUID()
        let secondScene = UUID()

        coordinator.acquire(owner: firstScene)
        coordinator.acquire(owner: secondScene)
        coordinator.release(owner: firstScene)
        #expect(spy.isIdleTimerDisabled)
        #expect(spy.updates == [true])

        coordinator.release(owner: secondScene)
        #expect(!spy.isIdleTimerDisabled)
        #expect(spy.updates == [true, false])
    }

    @MainActor
    @Test
    func promptSessionIdleTimerFollowsActiveInactiveActiveAndDisappearLifecycle() {
        let spy = IdleTimerControllerSpy()
        let coordinator = PromptSessionIdleTimerCoordinator(controller: spy)
        let session = UUID()

        // Appear while active.
        coordinator.update(isActive: true, owner: session)
        #expect(spy.isIdleTimerDisabled)
        // Scene becomes inactive.
        coordinator.update(isActive: false, owner: session)
        #expect(!spy.isIdleTimerDisabled)
        // The same visible session becomes active again.
        coordinator.update(isActive: true, owner: session)
        #expect(spy.isIdleTimerDisabled)
        // True disappearance releases its final lease.
        coordinator.release(owner: session)
        #expect(!spy.isIdleTimerDisabled)

        #expect(spy.updates == [true, false, true, false])
    }

    @MainActor
    @Test
    func promptSessionAndRecordingLeasesCanOverlapSafely() {
        let spy = IdleTimerControllerSpy()
        let coordinator = PromptSessionIdleTimerCoordinator(controller: spy)
        let promptSession = UUID()
        let recording = UUID()

        coordinator.update(isActive: true, owner: promptSession)
        coordinator.update(
            isActive: CaptureRecordingState.recording.preventsIdleSleep,
            owner: recording
        )
        coordinator.release(owner: promptSession)
        #expect(spy.isIdleTimerDisabled)
        #expect(spy.updates == [true])

        coordinator.update(
            isActive: CaptureRecordingState.stopping.preventsIdleSleep,
            owner: recording
        )
        #expect(!spy.isIdleTimerDisabled)
        #expect(spy.updates == [true, false])
    }

    @MainActor
    @Test
    func brandedLogoAssetLoadsFromTheAppBundle() {
        #expect(UIImage(named: "TextreamLogo") != nil)
    }

    @Test
    func aboutVersionLabelIncludesVersionAndBuild() {
        #expect(
            TextreamAppInfo.versionLabel(
                from: [
                    "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "45"
                ]
            ) == "Version 1.2.3 (45)"
        )
        #expect(
            TextreamAppInfo.versionLabel(
                from: ["CFBundleShortVersionString": "1.2.3"]
            ) == "Version 1.2.3"
        )
    }

    @Test
    func aboutLinksToTheTextreamMacApp() {
        #expect(
            TextreamAppInfo.macAppStoreURL.absoluteString
                == "https://apps.apple.com/app/textream/id6800061488"
        )
    }

    @Test
    func bundledOpenDyslexicLicenseIsAvailableToTheAboutScreen() throws {
        let url = try #require(
            Bundle.main.url(forResource: "OpenDyslexic-OFL", withExtension: "txt")
        )
        let license = try String(contentsOf: url, encoding: .utf8)
        #expect(license.contains("SIL OPEN FONT LICENSE Version 1.1"))
        #expect(license.contains("Reserved Font Name OpenDyslexic"))
    }

    @Test
    func turkishScriptSuggestsTheSupportedTurkishSpeechLocale() {
        let suggestion = SpeechLanguageDetector.suggestion(
            for: "Bu metin Türkçe yazılmış uzun bir cümledir ve konuşma dilinin doğru seçilmesi gerekir.",
            currentLocaleIdentifier: "en-US",
            supportedLocales: [Locale(identifier: "en-US"), Locale(identifier: "tr-TR")]
        )

        #expect(suggestion?.languageCode == "tr")
        #expect(suggestion?.localeIdentifier == "tr-TR")
        #expect((suggestion?.confidence ?? 0) >= 0.75)
    }

    @Test
    func matchingSpeechLanguageDoesNotShowASuggestion() {
        let suggestion = SpeechLanguageDetector.suggestion(
            for: "Bu metin Türkçe yazılmış uzun bir cümledir ve konuşma dilinin doğru seçilmesi gerekir.",
            currentLocaleIdentifier: "tr-TR",
            supportedLocales: [Locale(identifier: "en-US"), Locale(identifier: "tr-TR")]
        )

        #expect(suggestion == nil)
        #expect(
            SpeechLocaleSupport.matches(
                language: Locale.Language(identifier: "en-GB"),
                localeIdentifier: "en-US"
            )
        )
    }

    @Test
    func shortOrBracketOnlyTextDoesNotTriggerLanguageDetection() {
        let locales = [Locale(identifier: "en-US"), Locale(identifier: "tr-TR")]

        #expect(
            SpeechLanguageDetector.suggestion(
                for: "Kısa Türkçe metin",
                currentLocaleIdentifier: "en-US",
                supportedLocales: locales
            ) == nil
        )
        #expect(
            SpeechLanguageDetector.suggestion(
                for: "Read this. [Bu bölüm tamamen Türkçe yazılmış uzun bir sahne talimatıdır]",
                currentLocaleIdentifier: "en-US",
                supportedLocales: locales
            ) == nil
        )
    }

    @Test
    func lowConfidenceOrUnsupportedLanguagesAreNotSuggested() {
        let lowConfidence = SpeechLanguageDetector.suggestion(
            detectedLanguageIdentifier: "tr",
            confidence: 0.74,
            currentLocaleIdentifier: "en-US",
            supportedLocales: [Locale(identifier: "tr-TR")]
        )
        let unsupported = SpeechLanguageDetector.suggestion(
            detectedLanguageIdentifier: "tr",
            confidence: 0.99,
            currentLocaleIdentifier: "en-US",
            supportedLocales: [Locale(identifier: "en-US")]
        )

        #expect(lowConfidence == nil)
        #expect(unsupported == nil)
    }

    @Test
    func speechLocaleResolverPrefersScriptThenRegion() {
        let result = SpeechLocaleSupport.closestSupportedLocale(
            for: Locale.Language(identifier: "zh-Hant"),
            preferredRegion: Locale.Region("TW"),
            supportedLocales: [
                Locale(identifier: "zh-CN"),
                Locale(identifier: "zh-HK"),
                Locale(identifier: "zh-TW")
            ]
        )

        #expect(result?.identifier == "zh-TW")
    }

    @MainActor
    @Test
    func languageSuggestionCoordinatorRejectsStaleResultsAndRemembersDismissal() async throws {
        actor Stub {
            func suggestion(for text: String) async -> SpeechLanguageSuggestion? {
                if text == "old" {
                    try? await Task.sleep(for: .milliseconds(40))
                }
                return SpeechLanguageSuggestion(
                    detectedLanguageIdentifier: text == "old" ? "de" : "tr",
                    languageCode: text == "old" ? "de" : "tr",
                    localeIdentifier: text == "old" ? "de-DE" : "tr-TR",
                    confidence: 0.99
                )
            }
        }
        let stub = Stub()
        let coordinator = SpeechLanguageSuggestionCoordinator(
            debounceDuration: .zero,
            detector: { text, _ in await stub.suggestion(for: text) }
        )

        coordinator.schedule(text: "old", currentLocaleIdentifier: "en-US")
        await Task.yield()
        coordinator.schedule(text: "new", currentLocaleIdentifier: "en-US")
        for _ in 0..<100 where coordinator.suggestion == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(coordinator.suggestion?.localeIdentifier == "tr-TR")

        let suggestion = try #require(coordinator.suggestion)
        coordinator.dismiss(suggestion)
        coordinator.schedule(text: "new", currentLocaleIdentifier: "en-US")
        try? await Task.sleep(for: .milliseconds(10))
        #expect(coordinator.suggestion == nil)

        coordinator.reset(text: "new", currentLocaleIdentifier: "en-US")
        for _ in 0..<100 where coordinator.suggestion == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(coordinator.useSuggestedLocale() == "tr-TR")
        #expect(coordinator.suggestion == nil)
    }

    @MainActor
    @Test
    func savedRecordingIdentifiersStayNewestFirstAndUnique() {
        let normalized = SavedRecordingsStore.normalizedIdentifiers(
            ["new", "older", "new", "", "oldest"],
            limit: 2
        )

        #expect(normalized == ["new", "older"])
    }

    @MainActor
    @Test
    func savedRecordingStorePersistsOnlyTextreamAssetIdentifiers() {
        let suiteName = "SavedRecordingsStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SavedRecordingsStore(defaults: defaults, defaultsKey: "recordings")

        store.remember(assetIdentifier: "asset-1")
        store.remember(assetIdentifier: "asset-2")
        store.remember(assetIdentifier: "asset-1")

        #expect(store.recordedAssetIdentifiers == ["asset-1", "asset-2"])
        #expect(defaults.stringArray(forKey: "recordings") == ["asset-1", "asset-2"])
    }

    @MainActor
    @Test
    func forgettingSavedRecordingsPreservesOrderAndPersistsTheRemainder() {
        let suiteName = "SavedRecordingsForgetTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["newest", "middle", "oldest"], forKey: "recordings")
        let store = SavedRecordingsStore(defaults: defaults, defaultsKey: "recordings")

        store.forget(assetIdentifiers: ["middle", "not-remembered"])

        #expect(store.recordedAssetIdentifiers == ["newest", "oldest"])
        #expect(defaults.stringArray(forKey: "recordings") == ["newest", "oldest"])
    }

    @MainActor
    @Test
    func savingAnEditedCopyKeepsTheOriginalAndPersistsTheNewAssetFirst() {
        let suiteName = "SavedRecordingsEditPersistenceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["original"], forKey: "recordings")
        let store = SavedRecordingsStore(defaults: defaults, defaultsKey: "recordings")
        let editedCopy = SavedRecording(
            assetIdentifier: "trimmed-copy",
            thumbnail: UIImage(),
            createdAt: Date(timeIntervalSince1970: 100),
            duration: 4
        )

        // This is the deterministic state transition performed after Photos
        // successfully creates the trimmed copy.
        store.remember(assetIdentifier: editedCopy.assetIdentifier)
        store.cacheNewest(editedCopy)

        #expect(store.recordedAssetIdentifiers == ["trimmed-copy", "original"])
        #expect(defaults.stringArray(forKey: "recordings") == ["trimmed-copy", "original"])
        #expect(store.recordings.map(\.assetIdentifier) == ["trimmed-copy"])
    }

    @Test
    func nativeEditorTemporaryVideoCleanupIsIdempotent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextreamTrimCleanupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let videoURL = directory.appendingPathComponent("cancelled.mov")
        try Data([0, 1, 2, 3]).write(to: videoURL)
        #expect(FileManager.default.fileExists(atPath: videoURL.path))

        SavedRecordingsStore.removeTemporaryVideo(at: videoURL)
        #expect(!FileManager.default.fileExists(atPath: videoURL.path))

        // Cancel, failure, and repeated presentation teardown may all race to
        // clean the same file; cleanup must remain harmless.
        SavedRecordingsStore.removeTemporaryVideo(at: videoURL)
        SavedRecordingsStore.removeTemporaryVideo(at: nil)
        #expect(!FileManager.default.fileExists(atPath: videoURL.path))
    }

    @Test
    func nativeEditorWorkspacesAreUniqueAndOwnAStableMovSource() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextreamTrimWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let first = try SavedRecordingEditWorkspace.make(in: temporaryRoot)
        let second = try SavedRecordingEditWorkspace.make(in: temporaryRoot)

        #expect(first.directoryURL != second.directoryURL)
        #expect(first.sourceURL.lastPathComponent == "source.mov")
        #expect(second.sourceURL.lastPathComponent == "source.mov")
        #expect(first.sourceURL.deletingLastPathComponent() == first.directoryURL)
        #expect(FileManager.default.fileExists(atPath: first.directoryURL.path))
        #expect(FileManager.default.fileExists(atPath: second.directoryURL.path))
    }

    @MainActor
    @Test
    func nativeEditorUsesThePreparedVideoAndDoesNotLimitTrimDuration() throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("textream-native-editor-source.mov")
        try Data().write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let request = NativeVideoEditorRequest(sourceURL: sourceURL)
        let editor = UIVideoEditorController()
        NativeVideoEditor.configure(editor, sourceURL: request.sourceURL)

        #expect(request.sourceURL == sourceURL)
        #expect(editor.videoMaximumDuration == 0)
        #expect(editor.videoQuality == UIImagePickerController.QualityType.typeHigh)
    }

    @MainActor
    @Test
    func nativeEditorCompletesOnlyOnceAcrossCancelAndFailureCallbacks() {
        var completionCount = 0
        let coordinator = NativeVideoEditor.Coordinator { _ in
            completionCount += 1
        }
        let editor = UIVideoEditorController()

        coordinator.videoEditorControllerDidCancel(editor)
        coordinator.videoEditorController(
            editor,
            didFailWithError: SavedRecordingsEditError.exportUnavailable
        )

        #expect(completionCount == 1)
    }

    @Test
    func nativeEditorFailuresProvideUserFacingRecoveryMessages() {
        let failures: [SavedRecordingsEditError] = [
            .photosAccessDenied,
            .recordingUnavailable,
            .exportUnavailable,
            .nativeEditorUnavailable,
            .saveFailed("disk full")
        ]

        for failure in failures {
            #expect(!(failure.errorDescription ?? "").isEmpty)
        }
        #expect(
            SavedRecordingsEditError.saveFailed("disk full").errorDescription?
                .contains("disk full") == true
        )
    }

    @Test
    func savedRecordingsGridUsesBoundedResponsiveColumns() {
        #expect(SavedRecordingsGridLayout.columnCount(for: 393) == 2)
        #expect(SavedRecordingsGridLayout.columnCount(for: 844) == 4)
        #expect(SavedRecordingsGridLayout.itemWidth(for: 393) > 0)
        #expect(
            SavedRecordingsGridLayout.itemWidth(for: 393) * 2
                + SavedRecordingsGridLayout.spacing
                + SavedRecordingsGridLayout.horizontalPadding * 2
                <= 393.01
        )
        #expect(
            SavedRecordingsGridLayout.itemWidth(for: 844) * 4
                + SavedRecordingsGridLayout.spacing * 3
                + SavedRecordingsGridLayout.horizontalPadding * 2
                <= 844.01
        )

        // A full-width landscape phone and a large landscape device both keep
        // every tile inside the available bounds.
        for landscapeWidth in [852.0, 932.0, 1_194.0] {
            let columnCount = SavedRecordingsGridLayout.columnCount(for: landscapeWidth)
            let occupiedWidth = SavedRecordingsGridLayout.itemWidth(for: landscapeWidth)
                * CGFloat(columnCount)
                + SavedRecordingsGridLayout.spacing * CGFloat(columnCount - 1)
                + SavedRecordingsGridLayout.horizontalPadding * 2
            #expect(occupiedWidth <= landscapeWidth + 0.01)
        }
    }

    @Test
    func tokenizerCollapsesWhitespaceAndSplitsCJKCharacters() {
        let script = PromptScript("Hello\n\n世界  again")

        #expect(script.words.map(\.text) == ["Hello", "世", "界", "again"])
        #expect(script.text == "Hello 世 界 again")
    }

    @Test
    func balancedCuesAreAnnotationsButUnmatchedOpeningBracketIsReadable() {
        let balanced = PromptScript("Hello [look at camera] world")
        #expect(balanced.words.filter(\.isAnnotation).map(\.text) == ["[look", "at", "camera]"])

        let unmatched = PromptScript("Hello [unfinished world")
        #expect(!unmatched.words[1].isAnnotation)
        #expect(!unmatched.words[2].isAnnotation)
    }

    @Test
    func speechAnnotationRangesMatchMacIncludingEmptyCues() {
        let prompt = PromptScript("Lead [look at camera] middle [] stray] [unfinished")

        #expect(
            prompt.annotationRanges.map { String(Array(prompt.text)[$0]) }
                == ["[look at camera]", "[]"]
        )
    }

    @Test
    func annotationRangesFindEmbeddedAndAdjacentCuesExactly() {
        let prompt = PromptScript("hello[pause]world [one][two]")

        #expect(
            prompt.annotationRanges.map { String(Array(prompt.text)[$0]) }
                == ["[pause]", "[one]", "[two]"]
        )
        #expect(prompt.annotationRanges.first == 5..<12)
    }

    @Test
    func annotationRangesConvertToUTF16SafelyAfterEmoji() throws {
        let prompt = PromptScript("hello🙂 [gülümse] now")
        let range = try #require(prompt.annotationRanges.first)
        let utf16Range = prompt.nsRange(forCharacterRange: range)

        #expect(String(Array(prompt.text)[range]) == "[gülümse]")
        #expect(utf16Range == (prompt.text as NSString).range(of: "[gülümse]"))
    }

    @Test
    func editorBracketStylingMatchesMacAttributesAcrossTheWholeCue() throws {
        let source = "Read [look at camera] now"
        let font = UIFont.systemFont(ofSize: 17, weight: .regular)
        let attributedText = NSMutableAttributedString(string: source)

        BracketCueTextStyling.apply(to: attributedText, font: font)

        let cueRange = try #require(BracketCueTextStyling.ranges(in: source).first)
        for offset in cueRange.location..<NSMaxRange(cueRange) {
            let cueFont = try #require(
                attributedText.attribute(.font, at: offset, effectiveRange: nil) as? UIFont
            )
            let foreground = try #require(
                attributedText.attribute(.foregroundColor, at: offset, effectiveRange: nil)
                    as? UIColor
            )
            let background = try #require(
                attributedText.attribute(.backgroundColor, at: offset, effectiveRange: nil)
                    as? UIColor
            )

            #expect(cueFont.fontDescriptor.symbolicTraits.contains(.traitItalic))
            #expect(abs(cueFont.pointSize - font.pointSize) < 0.001)
            #expect(colorsMatch(foreground, .secondaryLabel))
            #expect(colorsMatch(background, .secondaryLabel.withAlphaComponent(0.08)))
        }

        let normalFont = try #require(
            attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        )
        let normalForeground = try #require(
            attributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        )
        #expect(normalFont == font)
        #expect(colorsMatch(normalForeground, .label))
        #expect(attributedText.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
    }

    @Test
    func editorBracketRangesAreBalancedNonemptyAndUTF16Safe() {
        let source = "🙂 x[inline]y [] stray] [unfinished"
        let ranges = BracketCueTextStyling.ranges(in: source)

        #expect(ranges == [(source as NSString).range(of: "[inline]")])
    }

    @Test
    func promptAnnotationStyleRangesSeparateAdjacentEmojiAndLeaveSuffixProseNormal() {
        let prompt = PromptScript("intro [pause]🙂 suffix [wait]continue")
        let characters = Array(prompt.text)
        let styledText = prompt.annotationStyleRanges.map { String(characters[$0]) }

        #expect(styledText == ["[pause]", "🙂", "[wait]"])
        #expect(prompt.annotationStyleRanges[0].upperBound == prompt.annotationStyleRanges[1].lowerBound)

        let suffixStart = prompt.annotationStyleRanges[2].upperBound
        #expect(characters[suffixStart] == "c")
        #expect(!prompt.annotationStyleRanges.contains { $0.contains(suffixStart) })
    }

    @MainActor
    @Test
    func prompterStylesTheFullCueSpanAtMacSizeWithReadAndUnreadOpacity() throws {
        let prompt = PromptScript("Say [look at camera] now")
        let initialView = makePromptTextView(
            prompt: prompt,
            highlightedCharacterCount: 0,
            wordTracking: true,
            continuousWordProgress: nil
        )
        let coordinator = initialView.makeCoordinator()
        let textView = PromptUITextView(usingTextLayoutManager: false)
        let cueRange = try #require(prompt.annotationRanges.first)
        let cueNSRange = prompt.nsRange(forCharacterRange: cueRange)

        coordinator.update(textView: textView, force: true)
        let unreadText = try #require(textView.attributedText)
        for offset in cueNSRange.location..<NSMaxRange(cueNSRange) {
            let cueFont = try #require(
                unreadText.attribute(.font, at: offset, effectiveRange: nil) as? UIFont
            )
            let foreground = try #require(
                unreadText.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? UIColor
            )
            #expect(cueFont.fontDescriptor.symbolicTraits.contains(.traitItalic))
            #expect(abs(cueFont.pointSize - 30) < 0.001)
            #expect(colorsMatch(foreground, .yellow.withAlphaComponent(0.2)))
        }

        coordinator.parent = makePromptTextView(
            prompt: prompt,
            highlightedCharacterCount: cueRange.upperBound,
            wordTracking: true,
            continuousWordProgress: nil
        )
        coordinator.update(textView: textView, force: false)

        let readText = try #require(textView.attributedText)
        for offset in cueNSRange.location..<NSMaxRange(cueNSRange) {
            let foreground = try #require(
                readText.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? UIColor
            )
            #expect(colorsMatch(foreground, .yellow.withAlphaComponent(0.5)))
        }
    }

    @MainActor
    @Test
    func prompterStylesOnlyTheEmbeddedCueInsideReadableProse() throws {
        let prompt = PromptScript("hello[pause]world")
        let view = makePromptTextView(
            prompt: prompt,
            highlightedCharacterCount: 0,
            wordTracking: true,
            continuousWordProgress: nil
        )
        let coordinator = view.makeCoordinator()
        let textView = PromptUITextView(usingTextLayoutManager: false)

        coordinator.update(textView: textView, force: true)

        let attributedText = try #require(textView.attributedText)
        let cueRange = try #require(prompt.annotationStyleRanges.first)
        let cueNSRange = prompt.nsRange(forCharacterRange: cueRange)
        for offset in cueNSRange.location..<NSMaxRange(cueNSRange) {
            let foreground = try #require(
                attributedText.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? UIColor
            )
            #expect(colorsMatch(foreground, .yellow.withAlphaComponent(0.2)))
        }

        let leadingColor = try #require(
            attributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        )
        let trailingColor = try #require(
            attributedText.attribute(
                .foregroundColor,
                at: NSMaxRange(cueNSRange),
                effectiveRange: nil
            ) as? UIColor
        )
        #expect(colorsMatch(leadingColor, .white))
        #expect(colorsMatch(trailingColor, .white))
    }

    @Test
    func matcherSkipsCueAndMovesForwardWithFuzzyTranscript() {
        var matcher = PromptMatcher(source: PromptScript("Welcome [smile] to the presentation today"))

        let first = matcher.match(transcript: "welcome to the")
        let second = matcher.match(transcript: "welcome to the presentation")

        #expect(first > "Welcome".count)
        #expect(second >= first)
        #expect(second > "Welcome [smile] to the".count)
    }

    @Test
    func matcherNeverMovesBackward() {
        var matcher = PromptMatcher(source: PromptScript("one two three four five six"))
        let forward = matcher.match(transcript: "one two three four")
        let stale = matcher.match(transcript: "one")

        #expect(stale == forward)
    }

    @Test
    func wordProgressRoundTripsCharacterOffsets() {
        let script = PromptScript("alpha beta gamma")
        let offset = script.characterOffset(forWordProgress: 1.5)

        #expect(offset == 8)
        #expect(abs(script.wordProgress(forCharacterOffset: offset) - 1.5) < 0.01)
    }

    @Test
    func voiceActivityUsesActivationFramesAndHangover() {
        var detector = VoiceActivityDetector()
        detector.process(level: 0.02, at: 10)
        #expect(!detector.isActive(at: 10))

        detector.process(level: 0.02, at: 10.05)
        #expect(detector.isActive(at: 10.5))
        #expect(!detector.isActive(at: 10.81))
    }

    @Test
    func audioSampleMeterComputesNormalizedRMS() {
        let level = AudioSampleLevelMeter.normalizedRMS([0.5, -0.5, 0.5, -0.5])

        #expect(abs(level - 0.5) < 0.000_1)
    }

    @Test
    func audioLevelPublishingIsCoalescedBeforeReachingTheMainActor() {
        let coalescer = AudioLevelCoalescer()
        let publications = (0..<100).compactMap { sample -> CGFloat? in
            coalescer.levelToPublish(
                CGFloat(sample) / 100,
                at: Double(sample) / 1_000
            )
        }

        #expect(publications.count == 2)
        #expect(publications.last == 0.67)
    }

    @MainActor
    @Test
    func audioLevelPublicationKeepsOneFixedSizeSnapshot() {
        let follower = SpeechFollower()

        follower.processAudioLevel(0.4, at: 1)

        #expect(follower.audioLevels.count == 30)
        #expect(follower.audioLevels.dropLast().allSatisfy { $0 == 0 })
        #expect(follower.audioLevels.last == 0.4)
    }

    @Test
    func audioAnalysisOutputRequiresBothMicrophoneAndAnalysis() {
        #expect(
            !CaptureController.shouldInstallAudioAnalysisOutput(
                audioEnabled: false,
                audioAnalysisEnabled: false
            )
        )
        #expect(
            !CaptureController.shouldInstallAudioAnalysisOutput(
                audioEnabled: true,
                audioAnalysisEnabled: false
            )
        )
        #expect(
            !CaptureController.shouldInstallAudioAnalysisOutput(
                audioEnabled: false,
                audioAnalysisEnabled: true
            )
        )
        #expect(
            CaptureController.shouldInstallAudioAnalysisOutput(
                audioEnabled: true,
                audioAnalysisEnabled: true
            )
        )
    }

    @Test
    func audioSampleMeterReadsCapturedFloatPCMBuffer() throws {
        let samples: [Float] = [0.25, -0.25, 0.25, -0.25]
        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: 44_100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var optionalFormatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &optionalFormatDescription
        )
        #expect(formatStatus == noErr)
        let formatDescription = try #require(optionalFormatDescription)

        let byteCount = samples.count * MemoryLayout<Float>.size
        var optionalBlockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &optionalBlockBuffer
        )
        #expect(blockStatus == noErr)
        let blockBuffer = try #require(optionalBlockBuffer)
        let copyStatus = samples.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        #expect(copyStatus == noErr)

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 44_100),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleSize = MemoryLayout<Float>.size
        var optionalSampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: samples.count,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &optionalSampleBuffer
        )
        #expect(sampleStatus == noErr)
        let sampleBuffer = try #require(optionalSampleBuffer)

        let level = try #require(AudioSampleLevelMeter.normalizedRMS(from: sampleBuffer))
        #expect(abs(level - 0.25) < 0.000_1)
    }

    @MainActor
    @Test
    func classicSessionTimerAdvancesFractionalWordProgress() async {
        let controller = PromptSessionController(
            configuration: makeConfiguration(
                sessionMode: .read,
                cameraEnabled: false,
                followMode: .classic
            )
        )
        await controller.prepare()
        let startingProgress = controller.continuousWordProgress ?? -1

        try? await Task.sleep(for: .milliseconds(250))

        #expect(controller.isPromptRunning)
        #expect((controller.continuousWordProgress ?? -1) > startingProgress + 0.2)
        controller.shutdown()
    }

    @MainActor
    @Test
    func voiceFollowerEntersSpeakingStateFromMicrophoneLevels() async {
        let follower = SpeechFollower()
        let source = PromptScript("one two three")
        #expect(await follower.prepare(source: source, mode: .voiceActivated, localeIdentifier: "en-US"))
        follower.start()

        follower.processAudioLevel(0.05)

        #expect(follower.isListening)
        #expect(follower.isSpeaking)
        follower.stop()
    }

    @MainActor
    @Test
    func fractionalWordProgressMovesPromptBeforeNextLineBecomesActive() {
        let prompt = PromptScript(
            "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen"
        )
        let textView = PromptUITextView(usingTextLayoutManager: false)
        textView.frame = CGRect(x: 0, y: 0, width: 210, height: 360)
        textView.readingPosition = .center
        textView.textContainer.lineFragmentPadding = 0
        textView.attributedText = NSAttributedString(
            string: prompt.text,
            attributes: [.font: UIFont.systemFont(ofSize: 32, weight: .semibold)]
        )
        textView.layoutIfNeeded()

        textView.scroll(toWordProgress: 0, in: prompt, animated: false)
        let startingOffset = textView.contentOffset.y
        textView.scroll(toWordProgress: 1.5, in: prompt, animated: false)

        #expect(startingOffset == 0)
        #expect(textView.contentOffset.y > startingOffset)
    }

    @MainActor
    @Test
    func fullBleedPromptKeepsFinalLineAboveBottomControlOverlay() {
        let prompt = PromptScript(
            "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen"
        )
        let textView = PromptUITextView(usingTextLayoutManager: false)
        textView.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
        textView.readingPosition = .center
        textView.topOverlayClearance = 56
        textView.bottomOverlayClearance = 116
        textView.horizontalTextInsets = UIEdgeInsets(
            top: 0,
            left: 64,
            bottom: 0,
            right: 52
        )
        textView.textContainer.lineFragmentPadding = 0
        textView.attributedText = NSAttributedString(
            string: prompt.text,
            attributes: [.font: UIFont.systemFont(ofSize: 32, weight: .semibold)]
        )
        textView.layoutIfNeeded()

        textView.scroll(
            toWordProgress: Double(prompt.words.count),
            in: prompt,
            animated: false
        )

        var finalLineMidY: CGFloat = 0
        let laidOutGlyphs = textView.layoutManager.glyphRange(for: textView.textContainer)
        textView.layoutManager.enumerateLineFragments(forGlyphRange: laidOutGlyphs) {
            _, usedRect, _, _, _ in
            finalLineMidY = usedRect.midY
        }
        let finalLineViewportMidY = finalLineMidY
            + textView.textContainerInset.top
            - textView.contentOffset.y

        #expect(textView.bounds.size == CGSize(width: 844, height: 390))
        #expect(textView.textContainerInset.left == 64)
        #expect(textView.textContainerInset.right == 52)
        #expect(textView.textContainer.lineFragmentPadding == 0)
        #expect(textView.effectiveAnchorY <= 390 - 116 - 12)
        #expect(textView.textContainerInset.bottom >= 116)
        #expect(abs(finalLineViewportMidY - textView.effectiveAnchorY) < 1)
    }

    @Test
    func readingPositionDefaultsNearCameraAndRespectsOverlayClearances() {
        let nearCamera = PromptReadingAnchorLayout.effectiveAnchorY(
            viewportHeight: 844,
            lineHeight: 44,
            position: .nearCamera,
            topOverlayClearance: 104,
            bottomOverlayClearance: 136
        )
        let center = PromptReadingAnchorLayout.effectiveAnchorY(
            viewportHeight: 844,
            lineHeight: 44,
            position: .center,
            topOverlayClearance: 104,
            bottomOverlayClearance: 136
        )

        #expect(nearCamera == 104 + PromptReadingAnchorLayout.overlayGap + 22)
        #expect(center == 422)
        #expect(nearCamera < center)
    }

    @Test
    func readingPositionStaysFiniteInShortLandscapeViewport() {
        let nearCamera = PromptReadingAnchorLayout.effectiveAnchorY(
            viewportHeight: 220,
            lineHeight: 56,
            position: .nearCamera,
            topOverlayClearance: 120,
            bottomOverlayClearance: 120
        )
        let center = PromptReadingAnchorLayout.effectiveAnchorY(
            viewportHeight: 220,
            lineHeight: 56,
            position: .center,
            topOverlayClearance: 120,
            bottomOverlayClearance: 120
        )

        #expect(nearCamera.isFinite)
        #expect(center.isFinite)
        #expect(nearCamera >= 28 && nearCamera <= 192)
        #expect(center >= 28 && center <= 192)
    }

    @Test
    func followNearCameraSelectsTheLastSpokenReadableCharacter() {
        let prompt = PromptScript("one [look left] two three")
        let two = prompt.words.first(where: { $0.text == "two" })!

        #expect(
            PromptUITextView.lastSpokenReadableCharacterOffset(
                recognizedCharacterCount: 0,
                in: prompt
            ) == 0
        )
        #expect(
            PromptUITextView.lastSpokenReadableCharacterOffset(
                recognizedCharacterCount: two.characterRange.lowerBound,
                in: prompt
            ) < two.characterRange.lowerBound
        )
        #expect(
            PromptUITextView.lastSpokenReadableCharacterOffset(
                recognizedCharacterCount: two.characterRange.upperBound,
                in: prompt
            ) == two.characterRange.upperBound - 1
        )
        #expect(
            PromptUITextView.lastSpokenReadableCharacterOffset(
                recognizedCharacterCount: prompt.characterCount,
                in: prompt
            ) == prompt.words.last!.characterRange.upperBound - 1
        )

        let unicodePrompt = PromptScript("hello🙂 世界 [pause]")
        let hello = unicodePrompt.words.first(where: { $0.text.hasPrefix("hello") })!
        let world = unicodePrompt.words.first(where: { $0.text == "界" })!
        #expect(
            PromptUITextView.lastSpokenReadableCharacterOffset(
                recognizedCharacterCount: hello.characterRange.upperBound,
                in: unicodePrompt
            ) == hello.characterRange.lowerBound + 4
        )
        #expect(
            PromptUITextView.lastSpokenReadableCharacterOffset(
                recognizedCharacterCount: world.characterRange.upperBound,
                in: unicodePrompt
            ) == world.characterRange.lowerBound
        )
    }

    @MainActor
    @Test
    func followNearCameraKeepsTheLastSpokenWrappedLineAtTheTopAnchor() {
        let prompt = PromptScript(
            "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen"
        )
        let textView = PromptUITextView(usingTextLayoutManager: false)
        textView.frame = CGRect(x: 0, y: 0, width: 220, height: 420)
        textView.readingPosition = .nearCamera
        textView.topOverlayClearance = 64
        textView.bottomOverlayClearance = 96
        textView.textContainer.lineFragmentPadding = 0
        textView.attributedText = NSAttributedString(
            string: prompt.text,
            attributes: [.font: UIFont.systemFont(ofSize: 32, weight: .semibold)]
        )
        textView.layoutIfNeeded()

        let spokenOffset = prompt.words[8].characterRange.upperBound
        textView.scrollLastSpokenLine(
            toCharacterOffset: spokenOffset,
            in: prompt,
            animated: false
        )
        let firstOffset = textView.contentOffset.y
        let sameLineOffset = prompt.words[9].characterRange.upperBound
        textView.scrollLastSpokenLine(
            toCharacterOffset: sameLineOffset,
            in: prompt,
            animated: false
        )

        let spokenCharacter = PromptUITextView.lastSpokenReadableCharacterOffset(
            recognizedCharacterCount: spokenOffset,
            in: prompt
        )
        let range = prompt.nsRange(
            forCharacterRange: spokenCharacter..<(spokenCharacter + 1)
        )
        let glyph = textView.layoutManager.glyphRange(
            forCharacterRange: range,
            actualCharacterRange: nil
        ).location
        let line = textView.layoutManager.lineFragmentUsedRect(
            forGlyphAt: glyph,
            effectiveRange: nil
        )
        let viewportMidY = line.midY
            + textView.textContainerInset.top
            - textView.contentOffset.y

        #expect(abs(viewportMidY - textView.effectiveAnchorY) < 1)
        #expect(viewportMidY > textView.topOverlayClearance)

        let firstLine = textView.layoutManager.lineFragmentUsedRect(
            forGlyphAt: glyph,
            effectiveRange: nil
        )
        let sameLineCharacter = PromptUITextView.lastSpokenReadableCharacterOffset(
            recognizedCharacterCount: sameLineOffset,
            in: prompt
        )
        let sameLineRange = prompt.nsRange(
            forCharacterRange: sameLineCharacter..<(sameLineCharacter + 1)
        )
        let sameLineGlyph = textView.layoutManager.glyphRange(
            forCharacterRange: sameLineRange,
            actualCharacterRange: nil
        ).location
        let sameLine = textView.layoutManager.lineFragmentUsedRect(
            forGlyphAt: sameLineGlyph,
            effectiveRange: nil
        )
        if abs(firstLine.midY - sameLine.midY) < 1 {
            #expect(abs(textView.contentOffset.y - firstOffset) < 1)
        }
    }

    @MainActor
    @Test
    func tapMappingDoesNotDoubleCountScrolledContentOffset() {
        let prompt = PromptScript(
            "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen"
        )
        let textView = PromptUITextView(usingTextLayoutManager: false)
        textView.frame = CGRect(x: 0, y: 0, width: 210, height: 220)
        textView.horizontalTextInsets = UIEdgeInsets(
            top: 0,
            left: 24,
            bottom: 0,
            right: 12
        )
        textView.textContainer.lineFragmentPadding = 0
        textView.attributedText = NSAttributedString(
            string: prompt.text,
            attributes: [.font: UIFont.systemFont(ofSize: 30, weight: .semibold)]
        )
        textView.layoutIfNeeded()

        let expectedWord = prompt.words[7]
        let characterRange = prompt.nsRange(forCharacterRange: expectedWord.characterRange)
        let glyphRange = textView.layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        let glyphRect = textView.layoutManager.boundingRect(
            forGlyphRange: glyphRange,
            in: textView.textContainer
        )
        let locationInScrolledViewCoordinates = CGPoint(
            x: glyphRect.midX + textView.textContainerInset.left,
            y: glyphRect.midY + textView.textContainerInset.top
        )
        textView.setContentOffset(CGPoint(x: 0, y: 80), animated: false)

        let tappedOffset = textView.characterOffset(
            at: locationInScrolledViewCoordinates,
            in: prompt
        )

        #expect(tappedOffset != nil)
        #expect(prompt.activeWord(atCharacterOffset: tappedOffset ?? 0)?.id == expectedWord.id)
    }

    @Test
    func followScrollAnimationMovesMonotonicallyAndCoalescesToLatestTarget() {
        let first = PromptScrollAnimation(
            startOffset: 0,
            targetOffset: 120,
            startTime: 10,
            duration: 0.4
        )
        let earlyOffset = first.offset(at: 10.1)
        let middleOffset = first.offset(at: 10.2)

        #expect(earlyOffset > 0)
        #expect(middleOffset > earlyOffset)
        #expect(middleOffset < first.targetOffset)

        let retargeted = first.retargeted(
            to: 200,
            at: 10.2,
            duration: 0.4
        )
        let retargetedMiddle = retargeted.offset(at: 10.3)

        #expect(abs(retargeted.startOffset - middleOffset) < 0.001)
        #expect(retargetedMiddle > retargeted.startOffset)
        #expect(retargetedMiddle < retargeted.targetOffset)
        #expect(retargeted.offset(at: 10.6) == 200)
        #expect(!PromptScrollAnimation.shouldAnimate(requested: true, reduceMotion: true))
        #expect(PromptScrollAnimation.shouldAnimate(requested: true, reduceMotion: false))
    }

    @MainActor
    @Test
    func followCoordinatorUsesAnimatedLineProgressWithoutResettingViewport() async {
        let prompt = PromptScript(
            "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen"
        )
        let initialView = makePromptTextView(
            prompt: prompt,
            highlightedCharacterCount: 0,
            wordTracking: true,
            continuousWordProgress: nil
        )
        let coordinator = initialView.makeCoordinator()
        let textView = PromptUITextView(usingTextLayoutManager: false)
        textView.frame = CGRect(x: 0, y: 0, width: 210, height: 220)
        coordinator.update(textView: textView, force: true)
        await drainMainQueue()
        textView.layoutIfNeeded()
        textView.setContentOffset(CGPoint(x: 0, y: 80), animated: false)

        let recognizedOffset = prompt.words[7].characterRange.upperBound
        coordinator.parent = makePromptTextView(
            prompt: prompt,
            highlightedCharacterCount: recognizedOffset,
            wordTracking: true,
            continuousWordProgress: nil
        )
        coordinator.update(textView: textView, force: false)

        // Updating read/current-word colors must not assign a new attributed
        // string and snap the viewport back to the top.
        #expect(textView.contentOffset.y == 80)
        await drainMainQueue()
        textView.cancelProgrammaticScrollAnimation()

        let request = PromptScrollRequest.resolve(
            prompt: prompt,
            highlightedCharacterCount: recognizedOffset,
            continuousWordProgress: nil,
            force: false
        )
        #expect(request.animated)
        #expect(
            abs(request.wordProgress - prompt.wordProgress(forCharacterOffset: recognizedOffset))
                < 0.000_1
        )
    }

    @Test
    func timerDrivenCoordinatorKeepsImmediateFractionalScrolling() {
        let prompt = PromptScript("one two three four five six seven eight")
        let request = PromptScrollRequest.resolve(
            prompt: prompt,
            highlightedCharacterCount: prompt.characterOffset(forWordProgress: 1.5),
            continuousWordProgress: 1.5,
            force: false
        )

        #expect(request.wordProgress == 1.5)
        #expect(!request.animated)
    }

    @Test
    func speedSwipeAxisLockAcceptsHorizontalIntentOnly() {
        #expect(PromptScrollSpeedAdjustment.isHorizontalSwipe(velocity: CGPoint(x: 180, y: 40)))
        #expect(!PromptScrollSpeedAdjustment.isHorizontalSwipe(velocity: CGPoint(x: 40, y: 180)))
        #expect(!PromptScrollSpeedAdjustment.isHorizontalSwipe(velocity: CGPoint(x: 100, y: 80)))
        #expect(!PromptScrollSpeedAdjustment.isHorizontalSwipe(velocity: CGPoint(x: 20, y: 0)))
    }

    @Test
    func speedSwipeUsesTranslationForSlowDragWithoutWeakeningAxisLock() {
        #expect(
            PromptScrollSpeedAdjustment.isHorizontalSwipe(
                velocity: CGPoint(x: 10, y: 2),
                translation: CGPoint(x: 18, y: 3)
            )
        )
        #expect(
            !PromptScrollSpeedAdjustment.isHorizontalSwipe(
                velocity: CGPoint(x: 2, y: 10),
                translation: CGPoint(x: 3, y: 18)
            )
        )
        #expect(
            !PromptScrollSpeedAdjustment.isHorizontalSwipe(
                velocity: CGPoint(x: 10, y: 8),
                translation: CGPoint(x: 12, y: 10)
            )
        )
    }

    @Test
    func speedSwipeUsesTotalTranslationAndClampsToSliderRange() {
        #expect(
            PromptScrollSpeedAdjustment.adjustedSpeed(
                startingSpeed: 3,
                horizontalTranslation: 100,
                viewWidth: 400
            ) == 4
        )
        #expect(
            PromptScrollSpeedAdjustment.adjustedSpeed(
                startingSpeed: 3,
                horizontalTranslation: 10,
                viewWidth: 400
            ) == 3
        )
        #expect(
            PromptScrollSpeedAdjustment.adjustedSpeed(
                startingSpeed: 7.5,
                horizontalTranslation: 500,
                viewWidth: 400
            ) == 8
        )
        #expect(
            PromptScrollSpeedAdjustment.adjustedSpeed(
                startingSpeed: 1,
                horizontalTranslation: -500,
                viewWidth: 400
            ) == 0.5
        )
    }

    @MainActor
    @Test
    func speedSwipeChangesAutoAndVoiceButNotFollow() {
        let classic = PromptSessionController(
            configuration: makeConfiguration(
                sessionMode: .read,
                cameraEnabled: false,
                followMode: .classic
            )
        )
        #expect(classic.canAdjustScrollSpeed)
        classic.beginScrollSpeedAdjustment()
        #expect(classic.isAdjustingScrollSpeed)
        classic.updateScrollSpeedAdjustment(horizontalTranslation: 100, viewWidth: 400)
        #expect(classic.scrollSpeed == 4)
        classic.finishScrollSpeedAdjustment()
        #expect(!classic.isAdjustingScrollSpeed)

        let voice = PromptSessionController(
            configuration: makeConfiguration(
                sessionMode: .read,
                cameraEnabled: false,
                followMode: .voiceActivated
            )
        )
        #expect(voice.canAdjustScrollSpeed)
        voice.beginScrollSpeedAdjustment()
        #expect(voice.isAdjustingScrollSpeed)
        voice.finishScrollSpeedAdjustment()
        #expect(!voice.isAdjustingScrollSpeed)

        let follow = PromptSessionController(
            configuration: makeConfiguration(
                sessionMode: .read,
                cameraEnabled: false,
                followMode: .wordTracking
            )
        )
        #expect(!follow.canAdjustScrollSpeed)
        follow.beginScrollSpeedAdjustment()
        follow.updateScrollSpeedAdjustment(horizontalTranslation: 100, viewWidth: 400)
        #expect(!follow.isAdjustingScrollSpeed)
        #expect(follow.scrollSpeed == 3)

        classic.shutdown()
        voice.shutdown()
        follow.shutdown()
    }

    @Test
    func textDirectionIgnoresCueBeforeFirstStrongCharacter() {
        #expect(PromptTextDirection.inferred(from: "[pause] مرحبا بالعالم") == .rightToLeft)
        #expect(PromptTextDirection.inferred(from: "[مرحبا] Hello world") == .leftToRight)
    }

    @Test
    func fontFamiliesMatchMacAppOptions() {
        #expect(PromptFontFamily.allCases.map(\.rawValue) == ["sans", "serif", "mono", "dyslexia"])
    }

    @Test
    func mirrorAxesMatchTheMacTeleprompterTransforms() {
        #expect(PromptMirrorAxis.horizontal.scaleX == -1)
        #expect(PromptMirrorAxis.horizontal.scaleY == 1)
        #expect(PromptMirrorAxis.vertical.scaleX == 1)
        #expect(PromptMirrorAxis.vertical.scaleY == -1)
        #expect(PromptMirrorAxis.both.scaleX == -1)
        #expect(PromptMirrorAxis.both.scaleY == -1)
        #expect(
            PromptMirrorAxis.allCases.map(\.rawValue)
                == ["horizontal", "vertical", "both"]
        )
    }

    @Test
    func mirrorPresentationRequiresAnEnabledLandscapeReadSession() {
        let landscape = CGSize(width: 844, height: 390)
        let portrait = CGSize(width: 390, height: 844)
        let square = CGSize(width: 500, height: 500)

        #expect(
            PromptMirrorPresentation.isActive(
                enabled: true,
                sessionMode: .read,
                viewportSize: landscape
            )
        )
        #expect(
            !PromptMirrorPresentation.isActive(
                enabled: false,
                sessionMode: .read,
                viewportSize: landscape
            )
        )
        #expect(
            !PromptMirrorPresentation.isActive(
                enabled: true,
                sessionMode: .read,
                viewportSize: portrait
            )
        )
        #expect(
            !PromptMirrorPresentation.isActive(
                enabled: true,
                sessionMode: .read,
                viewportSize: square
            )
        )
        #expect(
            !PromptMirrorPresentation.isActive(
                enabled: true,
                sessionMode: .record,
                viewportSize: landscape
            )
        )
    }

    @Test
    func mirrorPresentationKeepsSpeedSwipesInThePhysicalDeviceDirection() {
        #expect(
            PromptMirrorPresentation.deviceHorizontalTranslation(
                from: 120,
                isActive: false,
                axis: .horizontal
            ) == 120
        )
        #expect(
            PromptMirrorPresentation.deviceHorizontalTranslation(
                from: -120,
                isActive: true,
                axis: .horizontal
            ) == 120
        )
        #expect(
            PromptMirrorPresentation.deviceHorizontalTranslation(
                from: -120,
                isActive: true,
                axis: .both
            ) == 120
        )
        #expect(
            PromptMirrorPresentation.deviceHorizontalTranslation(
                from: 120,
                isActive: true,
                axis: .vertical
            ) == 120
        )
    }

    @Test
    func readModeCanRunWithoutCameraOrMicrophone() {
        let configuration = makeConfiguration(sessionMode: .read, cameraEnabled: false, followMode: .classic)

        #expect(!configuration.usesCamera)
        #expect(!configuration.requiresAudioCapture)
        #expect(!configuration.audioAnalysisEnabled)
    }

    @Test
    func cameraCanBeEnabledForReadMode() {
        let configuration = makeConfiguration(sessionMode: .read, cameraEnabled: true, followMode: .classic)

        #expect(configuration.usesCamera)
        #expect(!configuration.requiresAudioCapture)
        #expect(!configuration.audioAnalysisEnabled)
    }

    @Test
    func recordModeAlwaysRequestsCameraAndAudio() {
        let configuration = makeConfiguration(sessionMode: .record, cameraEnabled: false, followMode: .classic)

        #expect(configuration.usesCamera)
        #expect(configuration.requiresAudioCapture)
        #expect(!configuration.audioAnalysisEnabled)
    }

    @Test
    func voiceAndWordTrackingEnableAudioAnalysis() {
        let voice = makeConfiguration(
            sessionMode: .read,
            cameraEnabled: false,
            followMode: .voiceActivated
        )
        let wordTracking = makeConfiguration(
            sessionMode: .record,
            cameraEnabled: true,
            followMode: .wordTracking
        )

        #expect(voice.requiresAudioCapture)
        #expect(voice.audioAnalysisEnabled)
        #expect(wordTracking.requiresAudioCapture)
        #expect(wordTracking.audioAnalysisEnabled)
    }

    @Test
    func appModelPersistsCompanionPreferences() {
        let suiteName = "PromptCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = AppModel(defaults: defaults)
        #expect(first.readingPosition == .nearCamera)
        #expect(!first.mirrorEnabled)
        #expect(first.mirrorAxis == .horizontal)
        first.script = "A saved script"
        first.sessionMode = .record
        first.cameraEnabled = true
        first.followMode = .voiceActivated
        first.mirrorEnabled = true
        first.mirrorAxis = .both
        first.readingPosition = .center
        first.scrollSpeed = 5.5
        first.fontFamily = .dyslexia
        first.overlayOpacity = 0.65

        let restored = AppModel(defaults: defaults)
        #expect(restored.script == "A saved script")
        #expect(restored.sessionMode == .record)
        #expect(restored.cameraEnabled)
        #expect(restored.followMode == .voiceActivated)
        #expect(restored.mirrorEnabled)
        #expect(restored.mirrorAxis == .both)
        #expect(restored.readingPosition == .center)
        #expect(restored.scrollSpeed == 5.5)
        #expect(restored.fontFamily == .dyslexia)
        #expect(abs(restored.overlayOpacity - 0.65) < 0.001)
    }

    @Test
    func scriptEditsFlowVerbatimIntoThePromptConfiguration() {
        let suiteName = "PromptCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(defaults: defaults)
        let editedScript = "First line\n\n[look left] Second line"
        model.script = editedScript
        model.fontFamily = .dyslexia
        model.fontSize = .xl
        model.mirrorEnabled = true
        model.mirrorAxis = .vertical

        let configuration = model.configuration()

        #expect(configuration.script == editedScript)
        #expect(configuration.fontFamily == .dyslexia)
        #expect(configuration.fontSize == .xl)
        #expect(configuration.mirrorEnabled)
        #expect(configuration.mirrorAxis == .vertical)
        #expect(defaults.string(forKey: "ios.script") == editedScript)
    }

    @Test
    func liveDisplaySettingsStartFromTheSessionConfiguration() {
        let configuration = makeConfiguration(
            sessionMode: .read,
            cameraEnabled: false,
            followMode: .classic,
            mirrorEnabled: true,
            mirrorAxis: .vertical,
            readingPosition: .center,
            fontSize: .xl
        )

        let settings = PromptDisplaySettings(configuration: configuration)

        #expect(settings.mirrorEnabled)
        #expect(settings.mirrorAxis == .vertical)
        #expect(settings.readingPosition == .center)
        #expect(settings.fontSize == .xl)
    }

    @MainActor
    @Test
    func sessionSettingsClampLiveScrollSpeedToTheSupportedRange() {
        let controller = PromptSessionController(
            configuration: makeConfiguration(
                sessionMode: .read,
                cameraEnabled: false,
                followMode: .classic
            )
        )

        controller.setScrollSpeed(99)
        #expect(controller.scrollSpeed == PromptScrollSpeedAdjustment.maximumSpeed)

        controller.setScrollSpeed(-1)
        #expect(controller.scrollSpeed == PromptScrollSpeedAdjustment.minimumSpeed)
        controller.shutdown()
    }

    @MainActor
    @Test
    func appModelPersistsAColdLaunchSpeechLocaleWithoutEnumeratingSettings() {
        let suiteName = "PromptCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(defaults: defaults)

        #expect(!model.speechLocaleIdentifier.isEmpty)
        #expect(defaults.string(forKey: "ios.speechLocale") == model.speechLocaleIdentifier)
    }

    @Test
    func appModelRestoresRequiredRecordCamera() {
        let suiteName = "PromptCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(SessionMode.record.rawValue, forKey: "ios.sessionMode")
        defaults.set(false, forKey: "ios.cameraEnabled")

        let restored = AppModel(defaults: defaults)

        #expect(restored.sessionMode == .record)
        #expect(restored.cameraEnabled)
    }

    @Test
    func floatingStartButtonClearanceTracksItsMeasuredOverlay() {
        #expect(
            RootFloatingActionLayout.contentBottomClearance(measuredOverlayHeight: 82)
                == 82 + RootFloatingActionLayout.clearanceGap
        )
        #expect(
            RootFloatingActionLayout.contentBottomClearance(measuredOverlayHeight: 0)
                == RootFloatingActionLayout.fallbackOverlayHeight
                    + RootFloatingActionLayout.clearanceGap
        )
    }

    private func makeConfiguration(
        sessionMode: SessionMode,
        cameraEnabled: Bool,
        followMode: FollowMode,
        mirrorEnabled: Bool = false,
        mirrorAxis: PromptMirrorAxis = .horizontal,
        readingPosition: PromptReadingPosition = .nearCamera,
        fontSize: PromptFontSize = .lg
    ) -> PromptSessionConfiguration {
        PromptSessionConfiguration(
            script: "One two three",
            sessionMode: sessionMode,
            cameraEnabled: cameraEnabled,
            followMode: followMode,
            mirrorEnabled: mirrorEnabled,
            mirrorAxis: mirrorAxis,
            readingPosition: readingPosition,
            scrollSpeed: 3,
            fontFamily: .sans,
            fontSize: fontSize,
            textColor: .white,
            cueColor: .white,
            cueBrightness: .dim,
            overlayOpacity: 0.52,
            speechLocaleIdentifier: "en-US"
        )
    }

    private func makePromptTextView(
        prompt: PromptScript,
        highlightedCharacterCount: Int,
        wordTracking: Bool,
        continuousWordProgress: Double?
    ) -> PromptTextView {
        PromptTextView(
            prompt: prompt,
            highlightedCharacterCount: highlightedCharacterCount,
            font: .systemFont(ofSize: 30, weight: .semibold),
            textColor: .white,
            cueColor: .yellow,
            cueUnreadOpacity: 0.2,
            cueReadOpacity: 0.5,
            wordTracking: wordTracking,
            continuousWordProgress: continuousWordProgress,
            allowsHorizontalSpeedAdjustment: !wordTracking,
            readingPosition: .nearCamera,
            topOverlayClearance: 0,
            bottomOverlayClearance: 0,
            horizontalTextInsets: .zero,
            onWordTap: { _ in },
            onManualScrollBegan: {},
            onManualScrollEnded: { _ in },
            onSpeedAdjustmentBegan: {},
            onSpeedAdjustmentChanged: { _, _ in },
            onSpeedAdjustmentEnded: {}
        )
    }

    private func colorsMatch(
        _ lhs: UIColor,
        _ rhs: UIColor,
        tolerance: CGFloat = 0.001
    ) -> Bool {
        let traits = UITraitCollection(userInterfaceStyle: .dark)
        let left = lhs.resolvedColor(with: traits)
        let right = rhs.resolvedColor(with: traits)
        var leftRed: CGFloat = 0
        var leftGreen: CGFloat = 0
        var leftBlue: CGFloat = 0
        var leftAlpha: CGFloat = 0
        var rightRed: CGFloat = 0
        var rightGreen: CGFloat = 0
        var rightBlue: CGFloat = 0
        var rightAlpha: CGFloat = 0
        guard left.getRed(
            &leftRed,
            green: &leftGreen,
            blue: &leftBlue,
            alpha: &leftAlpha
        ), right.getRed(
            &rightRed,
            green: &rightGreen,
            blue: &rightBlue,
            alpha: &rightAlpha
        ) else { return left.isEqual(right) }

        return abs(leftRed - rightRed) <= tolerance
            && abs(leftGreen - rightGreen) <= tolerance
            && abs(leftBlue - rightBlue) <= tolerance
            && abs(leftAlpha - rightAlpha) <= tolerance
    }

    @MainActor
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
