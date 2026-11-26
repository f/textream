import Foundation
import AppKit
var failures = 0
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    if actual != expected { print("FAIL \(file):\(line): got \(actual), expected \(expected)"); failures += 1 }
}
func expectTrue(_ actual: Bool) { expectEqual(actual, true) }
func expectFalse(_ actual: Bool) { expectEqual(actual, false) }
func expectGreaterThan<T: Comparable>(_ actual: T, _ expected: T) { expectTrue(actual > expected) }

final class PromptNavigationTests {
    // Catches rewinding by words instead of actual display height, and choosing
    // the last word of a wrapped line instead of its first word.
    func testRewindsOneViewportToStartOfTargetLine() {
        let positions: [Int: CGFloat] = [0: 30, 1: 30, 2: 130, 3: 130, 4: 230, 5: 330, 6: 430]
        expectEqual(PromptNavigation.targetWord(for: .backOneScreen, currentWord: 6, viewportHeight: 150, wordPositions: positions), 4)
    }
    func testRewindClampsAtBeginning() {
        expectEqual(PromptNavigation.targetWord(for: .backOneScreen, currentWord: 1, viewportHeight: 500, wordPositions: [0: 30, 1: 130]), 0)
    }
    func testBeginningIgnoresCurrentPosition() {
        expectEqual(PromptNavigation.targetWord(for: .beginning, currentWord: 500, viewportHeight: 600, wordPositions: [:]), 0)
    }
    func testRewindCanReachWordsOutsideVisibleRows() {
        let positions = Dictionary(uniqueKeysWithValues: (0..<100).map { ($0, CGFloat($0 * 50 + 25)) })
        expectEqual(PromptNavigation.targetWord(for: .backOneScreen, currentWord: 90, viewportHeight: 800, wordPositions: positions), 74)
    }
    func testMissingLayoutDoesNotUnexpectedlyRestart() {
        expectEqual(PromptNavigation.targetWord(for: .backOneScreen, currentWord: 12, viewportHeight: 800, wordPositions: [:]), 12)
    }
    func testExternalFirstLineStartsAtCenter() {
        expectEqual(PromptNavigation.centeredOffset(wordY: 35, viewportHeight: 800), 365)
    }
    func testExternalCurrentLineRemainsCentered() {
        expectEqual(PromptNavigation.centeredOffset(wordY: 1235, viewportHeight: 800), -835)
    }
    func testSeekPreservesPauseAndSignalsRepeatedReset() {
        let playback = PrompterPlayback()
        playback.wordProgress = 80
        playback.isPaused = true
        playback.isUserScrolling = true
        playback.seek(to: 10)
        expectEqual(playback.wordProgress, 10)
        expectTrue(playback.isPaused)
        expectFalse(playback.isUserScrolling)
        let revision = playback.positionRevision
        playback.seek(to: 10)
        expectGreaterThan(playback.positionRevision, revision)
    }
    func testRewindIgnoresStaleVisibleWordMeasurements() {
        // Immediately after a jump, SwiftUI may still report the previous
        // visible rows. The complete layout already knows the destination.
        let positions = PromptNavigation.positionsForTracking(
            layout: [0: 40.5, 1: 40.5, 2: 129.5], measured: [0: 744, 10: 833]
        )
        expectEqual(PromptNavigation.centeredOffset(wordY: positions[0]!, viewportHeight: 420), 169.5)
        expectEqual(positions[10], 833)
    }
    func testReadingKeyboardBindings() {
        expectEqual(PrompterKeyboardShortcuts.command(keyCode: 123, modifiers: []), .backSentence)
        expectEqual(PrompterKeyboardShortcuts.command(keyCode: 126, modifiers: []), .backOneScreen)
        expectEqual(PrompterKeyboardShortcuts.command(keyCode: 124, modifiers: []), .forwardSentence)
        expectEqual(PrompterKeyboardShortcuts.command(keyCode: 125, modifiers: []), .forwardOneScreen)
        expectEqual(PrompterKeyboardShortcuts.command(keyCode: 126, modifiers: [.command]), .beginning)
        expectEqual(PrompterKeyboardShortcuts.command(keyCode: 126, modifiers: [.capsLock, .numericPad]), .backOneScreen)
    }
    func testReadingKeysDoNotCaptureEditingCombinations() {
        expectEqual(PrompterKeyboardShortcuts.command(keyCode: 123, modifiers: [.command]), nil)
        expectEqual(PrompterKeyboardShortcuts.command(keyCode: 126, modifiers: [.command, .option]), nil)
        expectEqual(PrompterKeyboardShortcuts.command(keyCode: 126, modifiers: [.shift]), nil)
        expectEqual(PrompterKeyboardShortcuts.command(keyCode: 124, modifiers: [.command]), nil)
    }
    func testSentenceRewindFindsStartOfCurrentSentence() {
        let words = ["Первое", "предложение.", "Второе", "предложение", "подлиннее.", "Третье", "предложение."]
        expectEqual(PromptNavigation.targetWord(for: .backSentence, currentWord: 4, viewportHeight: 0, wordPositions: [:], words: words), 2)
        expectEqual(PromptNavigation.targetWord(for: .backSentence, currentWord: 6, viewportHeight: 0, wordPositions: [:], words: words), 5)
    }
    func testRepeatedSentenceRewindGoesToPreviousSentence() {
        let words = ["Первое", "предложение.", "Второе", "предложение.", "Третье", "предложение."]
        expectEqual(PromptNavigation.targetWord(for: .backSentence, currentWord: 4, viewportHeight: 0, wordPositions: [:], words: words), 2)
        expectEqual(PromptNavigation.targetWord(for: .backSentence, currentWord: 2, viewportHeight: 0, wordPositions: [:], words: words), 0)
    }
    func testSentenceRewindHandlesBeginningAndUnpunctuatedText() {
        expectEqual(PromptNavigation.targetWord(for: .backSentence, currentWord: 0, viewportHeight: 0, wordPositions: [:], words: []), 0)
        expectEqual(PromptNavigation.targetWord(for: .backSentence, currentWord: 2, viewportHeight: 0, wordPositions: [:], words: ["Текст", "без", "пунктуации"]), 0)
    }
    func testForwardSentenceFindsNextSentence() {
        let words = ["Первое", "предложение.", "Второе", "предложение.", "Третье", "предложение."]
        expectEqual(PromptNavigation.targetWord(for: .forwardSentence, currentWord: 0, viewportHeight: 0, wordPositions: [:], words: words), 2)
        expectEqual(PromptNavigation.targetWord(for: .forwardSentence, currentWord: 3, viewportHeight: 0, wordPositions: [:], words: words), 4)
    }
    func testForwardSentenceDoesNotRewindOrFinishAtLastSentence() {
        let words = ["Первое", "предложение.", "Последнее", "длинное", "предложение."]
        expectEqual(PromptNavigation.targetWord(for: .forwardSentence, currentWord: 3, viewportHeight: 0, wordPositions: [:], words: words), 3)
        expectEqual(PromptNavigation.targetWord(for: .forwardSentence, currentWord: 4, viewportHeight: 0, wordPositions: [:], words: words), 4)
        expectEqual(PromptNavigation.targetWord(for: .forwardSentence, currentWord: 0, viewportHeight: 0, wordPositions: [:], words: []), 0)
    }
    func testForwardScreenUsesNextRowAtOneViewportDistance() {
        let positions: [Int: CGFloat] = [0: 30, 1: 30, 2: 130, 3: 130, 4: 230, 5: 330, 6: 430]
        expectEqual(PromptNavigation.targetWord(for: .forwardOneScreen, currentWord: 2, viewportHeight: 150, wordPositions: positions), 5)
    }
    func testForwardScreenClampsAtLastRowWithoutRewinding() {
        let positions: [Int: CGFloat] = [0: 30, 1: 130, 2: 230, 3: 230]
        expectEqual(PromptNavigation.targetWord(for: .forwardOneScreen, currentWord: 0, viewportHeight: 800, wordPositions: positions), 2)
        expectEqual(PromptNavigation.targetWord(for: .forwardOneScreen, currentWord: 3, viewportHeight: 800, wordPositions: positions), 3)
    }
    func testForwardScreenNeedsLayout() {
        expectEqual(PromptNavigation.targetWord(for: .forwardOneScreen, currentWord: 10, viewportHeight: 800, wordPositions: [:]), 10)
    }
    func testSeekClampsNegativeProgress() {
        let playback = PrompterPlayback()
        playback.seek(to: -8)
        expectEqual(playback.wordProgress, 0)
    }
}

let tests = PromptNavigationTests()
tests.testRewindsOneViewportToStartOfTargetLine()
tests.testRewindClampsAtBeginning()
tests.testBeginningIgnoresCurrentPosition()
tests.testRewindCanReachWordsOutsideVisibleRows()
tests.testMissingLayoutDoesNotUnexpectedlyRestart()
tests.testExternalFirstLineStartsAtCenter()
tests.testExternalCurrentLineRemainsCentered()
tests.testSeekPreservesPauseAndSignalsRepeatedReset()
tests.testSeekClampsNegativeProgress()
tests.testRewindIgnoresStaleVisibleWordMeasurements()
tests.testReadingKeyboardBindings()
tests.testReadingKeysDoNotCaptureEditingCombinations()
tests.testSentenceRewindFindsStartOfCurrentSentence()
tests.testRepeatedSentenceRewindGoesToPreviousSentence()
tests.testSentenceRewindHandlesBeginningAndUnpunctuatedText()
tests.testForwardSentenceFindsNextSentence()
tests.testForwardSentenceDoesNotRewindOrFinishAtLastSentence()
tests.testForwardScreenUsesNextRowAtOneViewportDistance()
tests.testForwardScreenClampsAtLastRowWithoutRewinding()
tests.testForwardScreenNeedsLayout()
print("20 navigation tests; \(failures) failed")
exit(failures == 0 ? 0 : 1)
