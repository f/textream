import XCTest

final class TrackingGuardTests: XCTestCase {
    func testAdvancesOnConfidentAlignedSpeech() {
        var guarder = TrackingGuard(text: "hello brave new world again")

        let frame = SpeechRecognitionFrame(
            partialText: "hello brave new",
            segments: [
                SpeechSegmentSnapshot(text: "hello", confidence: 0.92, timestamp: 0, duration: 0.1),
                SpeechSegmentSnapshot(text: "brave", confidence: 0.9, timestamp: 0.2, duration: 0.1),
                SpeechSegmentSnapshot(text: "new", confidence: 0.91, timestamp: 0.4, duration: 0.1),
            ],
            isFinal: false,
            createdAt: Date()
        )

        let snapshot = guarder.process(
            frame: frame,
            isSpeaking: true,
            strictTrackingEnabled: true,
            advanceThreshold: 3.0,
            windowSize: 8,
            offScriptFreezeDelay: 1.0,
            useLegacyFallback: false
        )

        XCTAssertEqual(snapshot.trackingState, .tracking)
        XCTAssertGreaterThan(snapshot.highlightedCharCount, 0)
        XCTAssertEqual(snapshot.expectedWord, "world")
    }

    func testOffScriptSpeechFreezesAndTurnsLost() {
        var guarder = TrackingGuard(text: "read only the script words")
        let now = Date()

        let first = SpeechRecognitionFrame(
            partialText: "totally different tangent",
            segments: [
                SpeechSegmentSnapshot(text: "totally", confidence: 0.75, timestamp: 0, duration: 0.1),
                SpeechSegmentSnapshot(text: "different", confidence: 0.74, timestamp: 0.2, duration: 0.1),
                SpeechSegmentSnapshot(text: "tangent", confidence: 0.73, timestamp: 0.4, duration: 0.1),
            ],
            isFinal: false,
            createdAt: now
        )

        let second = SpeechRecognitionFrame(
            partialText: "still off script",
            segments: [
                SpeechSegmentSnapshot(text: "still", confidence: 0.74, timestamp: 0.8, duration: 0.1),
                SpeechSegmentSnapshot(text: "off", confidence: 0.72, timestamp: 1.0, duration: 0.1),
                SpeechSegmentSnapshot(text: "script", confidence: 0.71, timestamp: 1.2, duration: 0.1),
            ],
            isFinal: false,
            createdAt: now.addingTimeInterval(1.3)
        )

        let firstSnapshot = guarder.process(
            frame: first,
            isSpeaking: true,
            strictTrackingEnabled: true,
            advanceThreshold: 3.0,
            windowSize: 8,
            offScriptFreezeDelay: 1.0,
            useLegacyFallback: false
        )
        let secondSnapshot = guarder.process(
            frame: second,
            isSpeaking: true,
            strictTrackingEnabled: true,
            advanceThreshold: 3.0,
            windowSize: 8,
            offScriptFreezeDelay: 1.0,
            useLegacyFallback: false
        )

        XCTAssertEqual(firstSnapshot.trackingState, .uncertain)
        XCTAssertEqual(secondSnapshot.trackingState, .lost)
        XCTAssertEqual(secondSnapshot.highlightedCharCount, 0)
    }

    func testManualAsideFreezesUntilReleased() {
        var guarder = TrackingGuard(text: "this should not advance while aside")
        _ = guarder.setManualAsideMode(.hold)

        let snapshot = guarder.process(
            frame: SpeechRecognitionFrame(
                partialText: "this should",
                segments: [
                    SpeechSegmentSnapshot(text: "this", confidence: 0.95, timestamp: 0, duration: 0.1),
                    SpeechSegmentSnapshot(text: "should", confidence: 0.95, timestamp: 0.2, duration: 0.1),
                ],
                isFinal: false,
                createdAt: Date()
            ),
            isSpeaking: true,
            strictTrackingEnabled: true,
            advanceThreshold: 3.0,
            windowSize: 8,
            offScriptFreezeDelay: 1.0,
            useLegacyFallback: false
        )

        XCTAssertEqual(snapshot.trackingState, .aside)
        XCTAssertEqual(snapshot.highlightedCharCount, 0)
    }

    func testRecoverRequiresTwoFramesAfterLost() {
        var guarder = TrackingGuard(text: "back on script after tangent")
        let base = Date()

        _ = guarder.process(
            frame: SpeechRecognitionFrame(
                partialText: "unrelated tangent",
                segments: [
                    SpeechSegmentSnapshot(text: "unrelated", confidence: 0.7, timestamp: 0, duration: 0.1),
                    SpeechSegmentSnapshot(text: "tangent", confidence: 0.7, timestamp: 0.2, duration: 0.1),
                ],
                isFinal: false,
                createdAt: base
            ),
            isSpeaking: true,
            strictTrackingEnabled: true,
            advanceThreshold: 3.0,
            windowSize: 8,
            offScriptFreezeDelay: 0.8,
            useLegacyFallback: false
        )

        let lost = guarder.process(
            frame: SpeechRecognitionFrame(
                partialText: "still tangent",
                segments: [
                    SpeechSegmentSnapshot(text: "still", confidence: 0.71, timestamp: 0.6, duration: 0.1),
                    SpeechSegmentSnapshot(text: "tangent", confidence: 0.71, timestamp: 0.8, duration: 0.1),
                ],
                isFinal: false,
                createdAt: base.addingTimeInterval(1.0)
            ),
            isSpeaking: true,
            strictTrackingEnabled: true,
            advanceThreshold: 3.0,
            windowSize: 8,
            offScriptFreezeDelay: 0.8,
            useLegacyFallback: false
        )

        let recovery1 = guarder.process(
            frame: SpeechRecognitionFrame(
                partialText: "back on script",
                segments: [
                    SpeechSegmentSnapshot(text: "back", confidence: 0.95, timestamp: 1.2, duration: 0.1),
                    SpeechSegmentSnapshot(text: "on", confidence: 0.95, timestamp: 1.4, duration: 0.1),
                    SpeechSegmentSnapshot(text: "script", confidence: 0.95, timestamp: 1.6, duration: 0.1),
                ],
                isFinal: false,
                createdAt: base.addingTimeInterval(1.4)
            ),
            isSpeaking: true,
            strictTrackingEnabled: true,
            advanceThreshold: 3.0,
            windowSize: 8,
            offScriptFreezeDelay: 0.8,
            useLegacyFallback: false
        )

        let recovery2 = guarder.process(
            frame: SpeechRecognitionFrame(
                partialText: "back on script after",
                segments: [
                    SpeechSegmentSnapshot(text: "back", confidence: 0.95, timestamp: 1.8, duration: 0.1),
                    SpeechSegmentSnapshot(text: "on", confidence: 0.95, timestamp: 2.0, duration: 0.1),
                    SpeechSegmentSnapshot(text: "script", confidence: 0.95, timestamp: 2.2, duration: 0.1),
                    SpeechSegmentSnapshot(text: "after", confidence: 0.95, timestamp: 2.4, duration: 0.1),
                ],
                isFinal: false,
                createdAt: base.addingTimeInterval(1.8)
            ),
            isSpeaking: true,
            strictTrackingEnabled: true,
            advanceThreshold: 3.0,
            windowSize: 8,
            offScriptFreezeDelay: 0.8,
            useLegacyFallback: false
        )

        XCTAssertEqual(lost.trackingState, .lost)
        XCTAssertEqual(recovery1.trackingState, .uncertain)
        XCTAssertEqual(recovery2.trackingState, .tracking)
        XCTAssertGreaterThan(recovery2.highlightedCharCount, 0)
    }

    func testCJKInputCanAdvanceOneCharacterAtATime() {
        var guarder = TrackingGuard(text: "你 好 世界")

        let snapshot = guarder.process(
            frame: SpeechRecognitionFrame(
                partialText: "你 好",
                segments: [
                    SpeechSegmentSnapshot(text: "你", confidence: 0.95, timestamp: 0, duration: 0.1),
                    SpeechSegmentSnapshot(text: "好", confidence: 0.95, timestamp: 0.2, duration: 0.1),
                ],
                isFinal: false,
                createdAt: Date()
            ),
            isSpeaking: true,
            strictTrackingEnabled: true,
            advanceThreshold: 2.2,
            windowSize: 8,
            offScriptFreezeDelay: 1.0,
            useLegacyFallback: false
        )

        XCTAssertEqual(snapshot.trackingState, .tracking)
        XCTAssertEqual(snapshot.expectedWord, "世")
    }

    func testBracketCueAutoSkipsInStrictMatching() {
        var guarder = TrackingGuard(text: "hello [wave] there")
        let base = Date()

        let first = guarder.process(
            frame: SpeechRecognitionFrame(
                partialText: "hello",
                segments: [
                    SpeechSegmentSnapshot(text: "hello", confidence: 0.95, timestamp: 0, duration: 0.1),
                ],
                isFinal: false,
                createdAt: base
            ),
            isSpeaking: true,
            strictTrackingEnabled: true,
            advanceThreshold: 2.0,
            windowSize: 8,
            offScriptFreezeDelay: 1.0,
            useLegacyFallback: false
        )

        XCTAssertEqual(first.expectedWord, "there")

        let second = guarder.process(
            frame: SpeechRecognitionFrame(
                partialText: "there",
                segments: [
                    SpeechSegmentSnapshot(text: "there", confidence: 0.95, timestamp: 0.2, duration: 0.1),
                ],
                isFinal: false,
                createdAt: base.addingTimeInterval(0.4)
            ),
            isSpeaking: true,
            strictTrackingEnabled: true,
            advanceThreshold: 2.0,
            windowSize: 8,
            offScriptFreezeDelay: 1.0,
            useLegacyFallback: false
        )

        XCTAssertEqual(second.trackingState, .tracking)
        XCTAssertEqual(second.expectedWord, "")
    }

    func testTrailingBracketCueDoesNotBlockDoneProgress() {
        var guarder = TrackingGuard(text: "hello [wave]")

        let snapshot = guarder.process(
            frame: SpeechRecognitionFrame(
                partialText: "hello",
                segments: [
                    SpeechSegmentSnapshot(text: "hello", confidence: 0.96, timestamp: 0, duration: 0.1),
                ],
                isFinal: false,
                createdAt: Date()
            ),
            isSpeaking: true,
            strictTrackingEnabled: true,
            advanceThreshold: 2.0,
            windowSize: 8,
            offScriptFreezeDelay: 1.0,
            useLegacyFallback: false
        )

        XCTAssertEqual(snapshot.highlightedCharCount, "hello [wave]".count)
        XCTAssertEqual(snapshot.expectedWord, "")
    }

    func testBracketCueHelpersStayStyledButAutoSkip() {
        XCTAssertTrue(isStyledAnnotationWord("[wave]"))
        XCTAssertFalse(wordParticipatesInTracking("[wave]"))
        XCTAssertTrue(shouldAutoSkipForTracking("[wave]"))
        XCTAssertTrue(shouldAutoSkipForTracking("👏"))
    }
}
