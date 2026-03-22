import XCTest

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

@MainActor
final class RemoteStateCompatibilityTests: XCTestCase {
    func testLegacyBrowserClientCanDecodeStateWithExtraFields() throws {
        let state = BrowserState(
            words: ["hello", "world"],
            highlightedCharCount: 5,
            totalCharCount: 11,
            audioLevels: [0.1, 0.2],
            isListening: true,
            isDone: false,
            fontColor: "#ffffff",
            cueColor: "#cccccc",
            hasNextPage: true,
            isActive: true,
            highlightWords: true,
            lastSpokenText: "hello",
            trackingState: "tracking",
            confidenceLevel: "medium",
            expectedWord: "world",
            nextCue: "again later",
            manualAsideActive: false
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(LegacyBrowserState.self, from: data)

        XCTAssertEqual(decoded.words, state.words)
        XCTAssertEqual(decoded.highlightedCharCount, state.highlightedCharCount)
        XCTAssertEqual(decoded.totalCharCount, state.totalCharCount)
        XCTAssertEqual(decoded.lastSpokenText, state.lastSpokenText)
    }

    func testLegacyDirectorClientCanDecodeStateWithExtraFields() throws {
        let state = DirectorState(
            words: ["hello", "world"],
            highlightedCharCount: 5,
            totalCharCount: 11,
            isActive: true,
            isDone: false,
            isListening: true,
            fontColor: "#ffffff",
            cueColor: "#cccccc",
            lastSpokenText: "hello",
            audioLevels: [0.1, 0.2],
            trackingState: "tracking",
            confidenceLevel: "medium",
            expectedWord: "world",
            nextCue: "again later",
            manualAsideActive: false
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(LegacyDirectorState.self, from: data)

        XCTAssertEqual(decoded.words, state.words)
        XCTAssertEqual(decoded.highlightedCharCount, state.highlightedCharCount)
        XCTAssertEqual(decoded.totalCharCount, state.totalCharCount)
        XCTAssertEqual(decoded.lastSpokenText, state.lastSpokenText)
    }
}
