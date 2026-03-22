import Foundation

/// Forward-only fallback tracker using fuzzy char/word matching.
/// Does not support backward matching — always returns .forward or .hold.
class FuzzyScriptTracker: ScriptTracker {
    private var sourceText: String = ""
    private var normalizedSource: String = ""
    private var matchStartOffset: Int = 0
    private var recognizedCharCount: Int = 0

    func loadScript(_ text: String, immediate: Bool = true) {
        sourceText = text
        normalizedSource = Self.normalize(text)
        matchStartOffset = 0
        recognizedCharCount = 0
    }

    func match(spoken: String) -> MatchResult {
        let charResult = charLevelMatch(spoken: spoken)
        let wordResult = wordLevelMatch(spoken: spoken)
        let best = max(charResult, wordResult)
        let newCount = matchStartOffset + best

        if newCount > recognizedCharCount {
            recognizedCharCount = min(newCount, sourceText.count)
            return MatchResult(
                charOffset: recognizedCharCount,
                confidence: 1.0,  // fuzzy matcher doesn't produce real confidence
                direction: .forward
            )
        }
        return .hold
    }

    func jumpTo(charOffset: Int) {
        recognizedCharCount = charOffset
        matchStartOffset = charOffset
    }

    func reset() {
        sourceText = ""
        normalizedSource = ""
        matchStartOffset = 0
        recognizedCharCount = 0
    }

    // MARK: - Matching Logic (extracted from SpeechRecognizer.swift)

    private func charLevelMatch(spoken: String) -> Int {
        let remainingSource = String(sourceText.dropFirst(matchStartOffset))
        let src = Array(remainingSource.lowercased().unicodeScalars).map { Character($0) }
        let spk = Array(Self.normalize(spoken).unicodeScalars).map { Character($0) }

        var si = 0
        var ri = 0
        var lastGoodOrigIndex = 0

        while si < src.count && ri < spk.count {
            let sc = src[si]
            let rc = spk[ri]

            // Skip non-alphanumeric in source
            if !sc.isLetter && !sc.isNumber {
                si += 1
                continue
            }
            // Skip non-alphanumeric in spoken
            if !rc.isLetter && !rc.isNumber {
                ri += 1
                continue
            }

            if sc == rc {
                si += 1
                ri += 1
                lastGoodOrigIndex = si
            } else {
                // Try to re-sync: look ahead in both strings
                var found = false

                // Skip up to 3 chars in spoken (STT inserted extra chars)
                let maxSkipR = min(3, spk.count - ri - 1)
                if maxSkipR >= 1 {
                    for skipR in 1...maxSkipR {
                        let nextRI = ri + skipR
                        if nextRI < spk.count && spk[nextRI] == sc {
                            ri = nextRI
                            found = true
                            break
                        }
                    }
                }
                if found { continue }

                // Skip up to 3 chars in source (STT missed some chars)
                let maxSkipS = min(3, src.count - si - 1)
                if maxSkipS >= 1 {
                    for skipS in 1...maxSkipS {
                        let nextSI = si + skipS
                        if nextSI < src.count && src[nextSI] == rc {
                            si = nextSI
                            found = true
                            break
                        }
                    }
                }
                if found { continue }

                // Skip both (substitution)
                si += 1
                ri += 1
                lastGoodOrigIndex = si
            }
        }

        return lastGoodOrigIndex
    }

    private static func isAnnotationWord(_ word: String) -> Bool {
        if word.hasPrefix("[") && word.hasSuffix("]") { return true }
        let stripped = word.filter { $0.isLetter || $0.isNumber }
        return stripped.isEmpty
    }

    private func wordLevelMatch(spoken: String) -> Int {
        let remainingSource = String(sourceText.dropFirst(matchStartOffset))
        let sourceWords = remainingSource.split(separator: " ").map { String($0) }
        let spokenWords = spoken.lowercased().split(separator: " ").map { String($0) }

        var si = 0 // source word index
        var ri = 0 // spoken word index
        var matchedCharCount = 0

        while si < sourceWords.count && ri < spokenWords.count {
            // Auto-skip annotation words in source (brackets, emoji)
            if Self.isAnnotationWord(sourceWords[si]) {
                matchedCharCount += sourceWords[si].count
                if si < sourceWords.count - 1 { matchedCharCount += 1 }
                si += 1
                continue
            }

            let srcWord = sourceWords[si].lowercased()
                .filter { $0.isLetter || $0.isNumber }
            let spkWord = spokenWords[ri]
                .filter { $0.isLetter || $0.isNumber }

            if srcWord == spkWord || isFuzzyMatch(srcWord, spkWord) {
                // Count original chars including trailing punctuation, plus space
                matchedCharCount += sourceWords[si].count
                if si < sourceWords.count - 1 {
                    matchedCharCount += 1 // space
                }
                si += 1
                ri += 1
            } else {
                // Try skipping up to 3 spoken words (STT hallucinated words)
                var foundSpk = false
                let maxSpkSkip = min(3, spokenWords.count - ri - 1)
                for skip in 1...max(1, maxSpkSkip) where skip <= maxSpkSkip {
                    let nextSpk = spokenWords[ri + skip].filter { $0.isLetter || $0.isNumber }
                    if srcWord == nextSpk || isFuzzyMatch(srcWord, nextSpk) {
                        ri += skip
                        foundSpk = true
                        break
                    }
                }
                if foundSpk { continue }

                // Try skipping up to 3 source words (user read fast, STT missed words)
                var foundSrc = false
                let maxSrcSkip = min(3, sourceWords.count - si - 1)
                for skip in 1...max(1, maxSrcSkip) where skip <= maxSrcSkip {
                    let nextSrc = sourceWords[si + skip].lowercased().filter { $0.isLetter || $0.isNumber }
                    if nextSrc == spkWord || isFuzzyMatch(nextSrc, spkWord) {
                        // Add all skipped source words' char counts
                        for s in 0..<skip {
                            matchedCharCount += sourceWords[si + s].count + 1
                        }
                        si += skip
                        foundSrc = true
                        break
                    }
                }
                if foundSrc { continue }

                // Try treating current source word as punctuation-only and skip it
                if srcWord.isEmpty {
                    matchedCharCount += sourceWords[si].count
                    if si < sourceWords.count - 1 { matchedCharCount += 1 }
                    si += 1
                    continue
                }
                // No match, advance spoken
                ri += 1
            }
        }

        // Auto-skip trailing annotation words at end of source
        while si < sourceWords.count && Self.isAnnotationWord(sourceWords[si]) {
            matchedCharCount += sourceWords[si].count
            if si < sourceWords.count - 1 { matchedCharCount += 1 }
            si += 1
        }

        return matchedCharCount
    }

    private func isFuzzyMatch(_ a: String, _ b: String) -> Bool {
        if a.isEmpty || b.isEmpty { return false }
        // Exact match
        if a == b { return true }
        // One starts with the other (phonetic prefix: "not" ~ "notch")
        if a.hasPrefix(b) || b.hasPrefix(a) { return true }
        // One contains the other
        if a.contains(b) || b.contains(a) { return true }
        // Shared prefix >= 60% of shorter word
        let shared = zip(a, b).prefix(while: { $0 == $1 }).count
        let shorter = min(a.count, b.count)
        if shorter >= 2 && shared >= max(2, shorter * 3 / 5) { return true }
        // Edit distance tolerance
        let dist = editDistance(a, b)
        if shorter <= 4 { return dist <= 1 }
        if shorter <= 8 { return dist <= 2 }
        return dist <= max(a.count, b.count) / 3
    }

    private func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var dp = Array(0...b.count)
        for i in 1...a.count {
            var prev = dp[0]
            dp[0] = i
            for j in 1...b.count {
                let temp = dp[j]
                dp[j] = a[i-1] == b[j-1] ? prev : min(prev, dp[j], dp[j-1]) + 1
                prev = temp
            }
        }
        return dp[b.count]
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
    }
}
