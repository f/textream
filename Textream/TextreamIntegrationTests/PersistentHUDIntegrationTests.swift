import XCTest
@testable import Textream

@MainActor
final class PersistentHUDIntegrationTests: XCTestCase {
    func testHUDPresenterFollowsVisibilityAndModuleChanges() {
        let input = HUDPresentationInput(
            trackingState: .tracking,
            expectedWord: "teleprompter",
            nextCue: "keeps moving smoothly"
        )

        let disabled = PersistentHUDPresenter.items(
            input: input,
            isListening: true,
            configuration: HUDPresentationConfiguration(
                isEnabled: false,
                modules: [.trackingState, .expectedWord]
            )
        )
        XCTAssertTrue(disabled.isEmpty)

        let enabled = PersistentHUDPresenter.items(
            input: input,
            isListening: true,
            configuration: HUDPresentationConfiguration(
                isEnabled: true,
                modules: [.trackingState, .expectedWord, .microphoneStatus]
            )
        )

        XCTAssertEqual(enabled.map(\.text), ["Tracking", "Now: teleprompter", "Mic On"])
    }

    func testHUDPresenterSurfacesAttachedFallbackStateAheadOfRegularModules() {
        let input = HUDPresentationInput(
            trackingState: .lost,
            expectedWord: "again",
            attachedRequiresAttention: true,
            attachedDiagnosticState: .targetLostFallback,
            attachedStatusLine: "Target window lost; using screen corner"
        )

        let items = PersistentHUDPresenter.items(
            input: input,
            isListening: false,
            configuration: HUDPresentationConfiguration(
                isEnabled: true,
                modules: [.trackingState, .expectedWord]
            )
        )

        XCTAssertEqual(items.first?.text, "Target window lost; using screen corner")
        XCTAssertEqual(items.dropFirst().map(\.text), ["Off Script", "Now: again"])
    }
}

@MainActor
final class RemoteStateCompatibilityIntegrationTests: XCTestCase {
    func testBrowserStateDecodesLegacyPayloadWithDefaultedTrackingFields() throws {
        let payload = """
        {
          "words": ["hello", "world"],
          "highlightedCharCount": 7,
          "totalCharCount": 11,
          "audioLevels": [0.2, 0.3],
          "isListening": true,
          "isDone": false,
          "fontColor": "#ffffff",
          "cueColor": "#00ffcc",
          "hasNextPage": true,
          "isActive": true,
          "highlightWords": true,
          "lastSpokenText": "hello"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(BrowserState.self, from: payload)

        XCTAssertEqual(decoded.words, ["hello", "world"])
        XCTAssertEqual(decoded.highlightedCharCount, 7)
        XCTAssertEqual(decoded.trackingState, TrackingState.tracking.rawValue)
        XCTAssertEqual(decoded.confidenceLevel, TrackingConfidence.low.rawValue)
        XCTAssertEqual(decoded.expectedWord, "")
        XCTAssertEqual(decoded.nextCue, "")
        XCTAssertFalse(decoded.manualAsideActive)
    }

    func testDirectorStateDecodesLegacyPayloadWithDefaultedTrackingFields() throws {
        let payload = """
        {
          "words": ["director"],
          "highlightedCharCount": 4,
          "totalCharCount": 8,
          "isActive": true,
          "isDone": false,
          "isListening": true,
          "fontColor": "#ffffff",
          "cueColor": "#f5f5f5",
          "lastSpokenText": "dire",
          "audioLevels": [0.5]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(DirectorState.self, from: payload)

        XCTAssertEqual(decoded.words, ["director"])
        XCTAssertEqual(decoded.highlightedCharCount, 4)
        XCTAssertEqual(decoded.trackingState, TrackingState.tracking.rawValue)
        XCTAssertEqual(decoded.confidenceLevel, TrackingConfidence.low.rawValue)
        XCTAssertEqual(decoded.expectedWord, "")
        XCTAssertEqual(decoded.nextCue, "")
        XCTAssertFalse(decoded.manualAsideActive)
    }

    func testLegacyBrowserClientCanDecodeCurrentServerPayload() throws {
        let payload = try JSONEncoder().encode(
            BrowserState(
                words: ["legacy", "client"],
                highlightedCharCount: 6,
                totalCharCount: 13,
                audioLevels: [0.1, 0.6],
                isListening: true,
                isDone: false,
                fontColor: "#ffffff",
                cueColor: "#00ffcc",
                hasNextPage: false,
                isActive: true,
                highlightWords: true,
                lastSpokenText: "legacy",
                trackingState: TrackingState.uncertain.rawValue,
                confidenceLevel: TrackingConfidence.medium.rawValue,
                expectedWord: "client",
                nextCue: "keeps old clients stable",
                manualAsideActive: true
            )
        )

        let decoded = try JSONDecoder().decode(LegacyBrowserState.self, from: payload)

        XCTAssertEqual(decoded.words, ["legacy", "client"])
        XCTAssertEqual(decoded.highlightedCharCount, 6)
        XCTAssertEqual(decoded.lastSpokenText, "legacy")
    }

    func testLegacyDirectorClientCanDecodeCurrentServerPayload() throws {
        let payload = try JSONEncoder().encode(
            DirectorState(
                words: ["legacy", "director"],
                highlightedCharCount: 5,
                totalCharCount: 15,
                isActive: true,
                isDone: false,
                isListening: true,
                fontColor: "#ffffff",
                cueColor: "#00ffcc",
                lastSpokenText: "legacy",
                audioLevels: [0.2],
                trackingState: TrackingState.tracking.rawValue,
                confidenceLevel: TrackingConfidence.high.rawValue,
                expectedWord: "director",
                nextCue: "remains compatible",
                manualAsideActive: false
            )
        )

        let decoded = try JSONDecoder().decode(LegacyDirectorState.self, from: payload)

        XCTAssertEqual(decoded.words, ["legacy", "director"])
        XCTAssertEqual(decoded.highlightedCharCount, 5)
        XCTAssertEqual(decoded.lastSpokenText, "legacy")
    }
}

private struct LegacyBrowserState: Decodable {
    let words: [String]
    let highlightedCharCount: Int
    let totalCharCount: Int
    let audioLevels: [Double]
    let isListening: Bool
    let isDone: Bool
    let fontColor: String
    let cueColor: String
    let hasNextPage: Bool
    let isActive: Bool
    let highlightWords: Bool
    let lastSpokenText: String
}

private struct LegacyDirectorState: Decodable {
    let words: [String]
    let highlightedCharCount: Int
    let totalCharCount: Int
    let isActive: Bool
    let isDone: Bool
    let isListening: Bool
    let fontColor: String
    let cueColor: String
    let lastSpokenText: String
    let audioLevels: [Double]
}
