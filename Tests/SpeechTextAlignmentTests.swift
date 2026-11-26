import Foundation

// Standalone tests for SpeechTextAlignment.bestOffset / shouldCommit.
//
// These can be run WITHOUT the Xcode project / project-file edits because
// SpeechTextAlignment.swift is a pure-Foundation enum. Compile & run:
//
//   swiftc -O \
//     Textream/Textream/SpeechTextAlignment.swift \
//     Tests/SpeechTextAlignmentTests.swift \
//     -o /tmp/SpeechTextAlignmentTests && /tmp/SpeechTextAlignmentTests
//
// Exit code 0 == all tests passed.

@main
struct SpeechTextAlignmentTests {
    static func main() {
        var failures: [String] = []
        var runCount = 0

        func assertEqual<T: Equatable>(
            _ actual: T,
            _ expected: T,
            _ name: String,
            file: String = #file,
            line: Int = #line
        ) {
            runCount += 1
            if actual != expected {
                failures.append("[FAIL] \(name)\n    expected: \(expected)\n    actual:   \(actual)\n    (\(file):\(line))")
            } else {
                print("[pass] \(name) -> \(actual)")
            }
        }

        // MARK: - bestOffset

        // 1. Agreement zone: average the two results.
        assertEqual(
            SpeechTextAlignment.bestOffset(characterResult: 100, wordResult: 110),
            105,
            "bestOffset.agreement.average"
        )

        // 2. Exact tie inside tolerance.
        assertEqual(
            SpeechTextAlignment.bestOffset(characterResult: 100, wordResult: 100),
            100,
            "bestOffset.agreement.exact"
        )

        // 3. Single optimistic fuzzy word result MUST NOT leap far ahead.
        //    charResult=0 (no character match) + wordResult=600 (a big fuzzy skip)
        //    -> capped to charResult + disagreementAllowance (0 + 30 = 30).
        assertEqual(
            SpeechTextAlignment.bestOffset(characterResult: 0, wordResult: 600),
            30,
            "bestOffset.disagreement.singleOptimisticCapped"
        )

        // 4. Word leads far with a real character anchor: capped to anchor + allowance.
        assertEqual(
            SpeechTextAlignment.bestOffset(characterResult: 200, wordResult: 800),
            230,
            "bestOffset.disagreement.wordLeadsCappedToAnchor"
        )

        // 5. Character result leads: it is trusted and preserved. A lagging word scan
        //    must not drag the cursor backward.
        assertEqual(
            SpeechTextAlignment.bestOffset(characterResult: 500, wordResult: 100),
            500,
            "bestOffset.disagreement.charLeadsPreserved"
        )

        // 6. Word leading by exactly the allowance is allowed through (boundary).
        assertEqual(
            SpeechTextAlignment.bestOffset(characterResult: 100, wordResult: 130),
            130,
            "bestOffset.disagreement.wordLeadsByExactlyAllowance"
        )

        // 7. Word leading by allowance + 1 is clamped (boundary + 1).
        assertEqual(
            SpeechTextAlignment.bestOffset(characterResult: 100, wordResult: 131),
            130,
            "bestOffset.disagreement.wordLeadsByAllowancePlusOneClamped"
        )

        // 8. Just-inside-tolerance (diff == tolerance): averaged, not capped.
        assertEqual(
            SpeechTextAlignment.bestOffset(characterResult: 100, wordResult: 120),
            110,
            "bestOffset.agreement.boundaryToleranceAveraged"
        )

        // 9. Just-outside-tolerance but still inside the allowance window
        //    (diff == 21, allowance == 30): word leads fully — NOT averaged and
        //    NOT yet clamped. This is the responsive catch-up window.
        assertEqual(
            SpeechTextAlignment.bestOffset(characterResult: 100, wordResult: 121),
            121,
            "bestOffset.disagreement.insideAllowanceNotClamped"
        )

        // 9b. The clamp only bites once the word leads by MORE than the allowance.
        assertEqual(
            SpeechTextAlignment.bestOffset(characterResult: 100, wordResult: 140),
            130,
            "bestOffset.disagreement.aboveAllowanceClamped"
        )

        // 10. Both zero: stays at zero.
        assertEqual(
            SpeechTextAlignment.bestOffset(characterResult: 0, wordResult: 0),
            0,
            "bestOffset.bothZero"
        )

        // 11. Responsive small advance preserved: word slightly ahead, within tolerance.
        assertEqual(
            SpeechTextAlignment.bestOffset(characterResult: 10, wordResult: 25),
            17,
            "bestOffset.responsive.smallAdvanceAveraged"
        )

        // 12. Custom allowance is honoured.
        assertEqual(
            SpeechTextAlignment.bestOffset(characterResult: 100, wordResult: 800, disagreementAllowance: 50),
            150,
            "bestOffset.customAllowance"
        )

        // 13. Custom tolerance is honoured.
        assertEqual(
            SpeechTextAlignment.bestOffset(characterResult: 100, wordResult: 140, agreementTolerance: 50),
            120,
            "bestOffset.customTolerance"
        )

        // MARK: - shouldCommit

        // 14. Both strategies progressed: trust the (now-conservative) candidate.
        assertEqual(
            SpeechTextAlignment.shouldCommit(
                characterResult: 100, wordResult: 50,
                current: 40, rawCandidate: 70, candidate: 70, confirmed: false
            ),
            true,
            "shouldCommit.bothProgressed"
        )

        // 15. Single strategy, small step: allowed (responsive).
        assertEqual(
            SpeechTextAlignment.shouldCommit(
                characterResult: 0, wordResult: 10,
                current: 0, rawCandidate: 10, candidate: 10, confirmed: false
            ),
            true,
            "shouldCommit.singleStrategy.smallStep"
        )

        // 16. Single strategy, large unconfirmed jump: blocked.
        assertEqual(
            SpeechTextAlignment.shouldCommit(
                characterResult: 0, wordResult: 100,
                current: 0, rawCandidate: 100, candidate: 100, confirmed: false
            ),
            false,
            "shouldCommit.singleStrategy.largeUnconfirmed"
        )

        // 17. Single strategy, large jump that is confirmed by repeated results: allowed.
        assertEqual(
            SpeechTextAlignment.shouldCommit(
                characterResult: 0, wordResult: 100,
                current: 0, rawCandidate: 100, candidate: 100, confirmed: true
            ),
            true,
            "shouldCommit.singleStrategy.confirmed"
        )

        // 18. Annotation skip: candidate advanced past annotation -> allowed.
        assertEqual(
            SpeechTextAlignment.shouldCommit(
                characterResult: 0, wordResult: 5,
                current: 5, rawCandidate: 5, candidate: 40, confirmed: false
            ),
            true,
            "shouldCommit.skippedAnnotation"
        )

        // MARK: - Integration scenario

        // Speaker confirmed at char 200; a fuzzy word skip hallucinates 600 chars
        // of progress while the character scan confirms 210. The combined offset
        // must be bounded, NOT 600-ish.
        let combined = SpeechTextAlignment.bestOffset(characterResult: 210, wordResult: 600)
        assertEqual(combined <= 210 + 30, true, "integration.optimisticFuzzyBoundedFlag")
        assertEqual(combined, 240, "integration.optimisticFuzzyBoundedValue")

        // And it remains committable because the *combined* offset is already
        // conservative (240, not 600), so 200 -> 240 is a safe ~word-length nudge.
        let commit = SpeechTextAlignment.shouldCommit(
            characterResult: 210, wordResult: 600,
            current: 200, rawCandidate: combined, candidate: combined, confirmed: false
        )
        assertEqual(commit, true, "integration.optimisticFuzzyStillCommitsBecauseBounded")

        // MARK: - Result

        print("")
        if failures.isEmpty {
            print("All \(runCount) assertions passed.")
            exit(0)
        } else {
            print("\(failures.count) of \(runCount) assertions failed:")
            for f in failures { print(f) }
            exit(1)
        }
    }
}
