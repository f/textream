import Foundation

// Keep the real recognizer's transcript path independent of user preferences.
final class NotchSettings {
    enum ListeningMode { case wordTracking }
    static let shared = NotchSettings()
    let speechLocale = "en-US"
    let selectedMicUID = ""
    let listeningMode = ListeningMode.wordTracking
}

@main
struct SpeechRecoveryTests {
    static func check(_ condition: @autoclosure () -> Bool, _ description: String) {
        guard condition() else {
            fputs("FAIL: \(description)\n", stderr)
            exit(1)
        }
        print("PASS: \(description)")
    }

    static func end(of phrase: String, in text: String) -> Int {
        let range = text.range(of: phrase)!
        return text.distance(from: text.startIndex, to: range.upperBound)
    }

    static func main() {
        let english = "New extraordinary interconnected computational research methods and technologies are changing our everyday lives around the world."
        let matcher = SpeechRecoveryMatcher(text: english, locale: Locale(identifier: "en-US"))
        let anchor = end(of: "New", in: english)
        let target = end(of: "changing our everyday lives", in: english)
        check(
            matcher.recoveredOffset(spoken: "New something wrong changing our everyday lives", currentOffset: anchor) == target,
            "recovers after several misread or omitted words"
        )
        check(
            matcher.recoveredOffset(spoken: "our everyday lives", currentOffset: anchor) == target,
            "reacquires the next clear three-word phrase"
        )
        check(
            matcher.recoveredOffset(spoken: "changing our", currentOffset: anchor) == nil,
            "waits for phrase evidence instead of a common one- or two-word match"
        )
        check(
            matcher.recoveredOffset(spoken: "please pause I need a glass of water", currentOffset: anchor) == nil,
            "unrelated speech does not recover forward"
        )
        check(
            matcher.recoveredOffset(spoken: "our everyday lives", currentOffset: target) == nil,
            "repeating the previous result does not advance again"
        )
        let next = end(of: "around the world.", in: english)
        check(
            matcher.recoveredOffset(spoken: "around the world", currentOffset: target) == next,
            "normal reading can continue after reacquisition"
        )

        let turkish = "Bugün yapay zekânın olağanüstü gelişmelerini ve bilimsel araştırmalarını konuşacağız. Teknoloji günlük hayatımızı hızla değiştiriyor."
        let turkishMatcher = SpeechRecoveryMatcher(text: turkish, locale: Locale(identifier: "tr-TR"))
        check(
            turkishMatcher.recoveredOffset(spoken: "bir kelimeyi yanlış söyledim teknoloji günlük hayatımızı", currentOffset: 5)
                == end(of: "Teknoloji günlük hayatımızı", in: turkish),
            "Turkish reading resumes after a mispronunciation"
        )
        let dottedI = "Yeni İLERİ ARAŞTIRMALAR İNSANLIĞI DEĞİŞTİRİYOR."
        check(
            SpeechRecoveryMatcher(text: dottedI, locale: Locale(identifier: "tr-TR"))
                .recoveredOffset(spoken: "ileri araştırmalar insanlığı değiştiriyor", currentOffset: 0) == dottedI.count,
            "Turkish dotted and dotless I retain correct character offsets"
        )

        let repeated = "Please read the important research findings and then read the important research findings again."
        check(
            SpeechRecoveryMatcher(text: repeated, locale: Locale(identifier: "en-US"))
                .recoveredOffset(spoken: "important research findings", currentOffset: 0) == nil,
            "ambiguous repeated phrases do not skip ahead"
        )
        let distant = "Start " + Array(repeating: "unread", count: 30).joined(separator: " ") + " important research findings"
        check(
            SpeechRecoveryMatcher(text: distant, locale: Locale(identifier: "en-US"))
                .recoveredOffset(spoken: "important research findings", currentOffset: 0) == nil,
            "three words are insufficient to skip a large section"
        )
        let longLag = "Start " + Array(repeating: "unread", count: 45).joined(separator: " ")
            + " researchers discover entirely new scientific methods today."
        check(
            SpeechRecoveryMatcher(text: longLag, locale: Locale(identifier: "en-US"))
                .recoveredOffset(spoken: "researchers discover entirely new scientific methods", currentOffset: 0)
                == end(of: "researchers discover entirely new scientific methods", in: longLag),
            "a clear six-word phrase recovers a substantial accumulated lag"
        )
        let tooFar = "Start " + Array(repeating: "unread", count: 90).joined(separator: " ")
            + " researchers discover entirely new scientific methods today."
        check(
            SpeechRecoveryMatcher(text: tooFar, locale: Locale(identifier: "en-US"))
                .recoveredOffset(spoken: "researchers discover entirely new scientific methods", currentOffset: 0) == nil,
            "recovery remains bounded even for a strong phrase"
        )
        let cues = "Today [PAUSE AND LOOK AT CAMERA] new research changes everyday life."
        check(
            SpeechRecoveryMatcher(text: cues, locale: Locale(identifier: "en-US"))
                .recoveredOffset(spoken: "new research changes everyday life", currentOffset: 0) == cues.count,
            "silent stage directions do not block recovery or corrupt offsets"
        )
        check(
            SpeechRecoveryMatcher(text: cues, locale: Locale(identifier: "en-US"))
                .recoveredOffset(spoken: "pause and look at camera", currentOffset: 0) == nil,
            "stage directions are not treated as spoken anchors"
        )
        check(matcher.recoveredOffset(spoken: "", currentOffset: 0) == nil, "silence cannot advance the prompt")

        let recognizer = SpeechRecognizer()
        recognizer.updateText(english, preservingCharCount: anchor)
        let misreadTranscript = "New something wrong changing our everyday lives"
        recognizer.matchCharacters(spoken: misreadTranscript)
        let recovered = recognizer.recognizedCharCount
        check(recovered >= target && recovered <= target + 1, "the real recognizer recovers the reading position")
        recognizer.matchCharacters(spoken: misreadTranscript)
        check(recognizer.recognizedCharCount == recovered, "a repeated partial result cannot advance the recovered recognizer")
        recognizer.matchCharacters(spoken: "")
        check(recognizer.recognizedCharCount == recovered, "silence leaves the real recognizer at the same position")
        recognizer.matchCharacters(spoken: misreadTranscript + " around")
        check(recognizer.recognizedCharCount > recovered, "the first new word advances after recovery")
        recognizer.matchCharacters(spoken: misreadTranscript + " around the world")
        check(recognizer.recognizedCharCount >= english.count - 1, "continuous speech reaches the end after recovery")

        let laggingRecognizer = SpeechRecognizer()
        laggingRecognizer.updateText(longLag, preservingCharCount: 5)
        let laterTranscript = "something went wrong researchers discover entirely new scientific methods"
        laggingRecognizer.matchCharacters(spoken: laterTranscript)
        check(
            laggingRecognizer.recognizedCharCount >= end(of: "researchers discover entirely new scientific methods", in: longLag),
            "the real recognizer can catch up after a long stall"
        )
        laggingRecognizer.matchCharacters(spoken: laterTranscript + " today")
        check(laggingRecognizer.recognizedCharCount >= longLag.count - 1, "reading continues immediately after a long recovery")

        print("All speech recovery checks passed.")
    }
}
