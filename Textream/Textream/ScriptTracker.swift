import Foundation

enum MatchDirection {
    case forward
    case backward
    case hold
}

struct MatchResult {
    let charOffset: Int
    let confidence: Float
    let direction: MatchDirection

    static let hold = MatchResult(charOffset: 0, confidence: 0, direction: .hold)
}

struct ScriptSegment {
    let text: String
    let charRange: Range<Int>
    var embedding: [Float]?
    let isAnnotation: Bool  // excluded from similarity matching
}

protocol ScriptTracker: AnyObject {
    /// Load and segment script text. Triggers background embedding for semantic tracker.
    /// Pass `immediate: false` for rapid live-edit calls (debounces embedding).
    func loadScript(_ text: String, immediate: Bool)

    /// Match spoken text against the script. Returns position and direction.
    func match(spoken: String) -> MatchResult

    /// Recenter the search window around this character offset (e.g., user tap).
    func jumpTo(charOffset: Int)

    /// Clear all state for a new session.
    func reset()
}
