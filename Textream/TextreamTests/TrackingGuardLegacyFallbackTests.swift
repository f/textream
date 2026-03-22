import XCTest

final class TrackingGuardLegacyFallbackTests: XCTestCase {
    func testLegacyFallbackAdvancesWhenStrictTrackingDisabled() {
        var guarder = TrackingGuard(text: "legacy fallback should advance here")

        let snapshot = guarder.process(
            frame: SpeechRecognitionFrame(
                partialText: "legacy fallback",
                segments: [
                    SpeechSegmentSnapshot(text: "legacy", confidence: 0.8, timestamp: 0, duration: 0.1),
                ],
                isFinal: false,
                createdAt: Date()
            ),
            isSpeaking: true,
            strictTrackingEnabled: false,
            advanceThreshold: 3.0,
            windowSize: 8,
            offScriptFreezeDelay: 1.0,
            useLegacyFallback: true
        ) { _, startOffset in
            startOffset + 12
        }

        XCTAssertEqual(snapshot.trackingState, .tracking)
        XCTAssertEqual(snapshot.decisionReason, .legacyFallbackAdvance)
        XCTAssertEqual(snapshot.highlightedCharCount, 12)
    }

    func testLegacyFallbackFreezesWhenHeardSpeechButCouldNotAdvance() {
        var guarder = TrackingGuard(text: "legacy fallback should freeze")
        let firstDate = Date()

        let first = guarder.process(
            frame: SpeechRecognitionFrame(
                partialText: "side tangent",
                segments: [
                    SpeechSegmentSnapshot(text: "side", confidence: 0.7, timestamp: 0, duration: 0.1),
                ],
                isFinal: false,
                createdAt: firstDate
            ),
            isSpeaking: true,
            strictTrackingEnabled: false,
            advanceThreshold: 3.0,
            windowSize: 8,
            offScriptFreezeDelay: 0.8,
            useLegacyFallback: true
        ) { _, startOffset in
            startOffset
        }

        let second = guarder.process(
            frame: SpeechRecognitionFrame(
                partialText: "still tangent",
                segments: [
                    SpeechSegmentSnapshot(text: "still", confidence: 0.7, timestamp: 0.9, duration: 0.1),
                ],
                isFinal: false,
                createdAt: firstDate.addingTimeInterval(1.0)
            ),
            isSpeaking: true,
            strictTrackingEnabled: false,
            advanceThreshold: 3.0,
            windowSize: 8,
            offScriptFreezeDelay: 0.8,
            useLegacyFallback: true
        ) { _, startOffset in
            startOffset
        }

        XCTAssertEqual(first.trackingState, .uncertain)
        XCTAssertEqual(first.decisionReason, .legacyFallbackNoAdvance)
        XCTAssertEqual(second.trackingState, .lost)
        XCTAssertEqual(second.highlightedCharCount, 0)
    }

    func testStrictTrackingDoesNotInvokeLegacyFallbackClosure() {
        var guarder = TrackingGuard(text: "strict tracking should ignore legacy fallback")
        var didInvokeLegacy = false

        let snapshot = guarder.process(
            frame: SpeechRecognitionFrame(
                partialText: "",
                segments: [],
                isFinal: false,
                createdAt: Date()
            ),
            isSpeaking: false,
            strictTrackingEnabled: true,
            advanceThreshold: 3.0,
            windowSize: 8,
            offScriptFreezeDelay: 1.0,
            useLegacyFallback: true
        ) { _, startOffset in
            didInvokeLegacy = true
            return startOffset + 20
        }

        XCTAssertFalse(didInvokeLegacy)
        XCTAssertEqual(snapshot.highlightedCharCount, 0)
    }
}
