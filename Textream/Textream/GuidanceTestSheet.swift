//
//  GuidanceTestSheet.swift
//  Textream
//
//  A small free-speech check for the engine selected in Guidance settings.
//

import SwiftUI

private struct LocalTranscriptAccumulator {
    private static let minimumAnchorLength = 6
    private static let maximumAnchorLength = 80

    private struct TailAlignment {
        var tail: [Character]
        var consumedCount: Int
    }

    private var committed: [Character] = []
    private var previousTail: [Character] = []
    private(set) var display = ""

    mutating func update(with hypothesis: String, stablePrefix: String) -> String {
        let incoming = Array(hypothesis)
        guard !incoming.isEmpty else { return display }
        guard let alignment = unrepresentedTail(in: incoming) else {
            // Completed text is append-only. If a decoder revision removes
            // every usable anchor, wait for the next hypothesis instead of
            // replacing words the user has already seen as completed.
            return display
        }
        let tail = alignment.tail

        let commonCount = zip(previousTail, tail).prefix { $0 == $1 }.count
        let agreedWordBoundary = Self.confirmedWordBoundary(
            in: tail,
            through: commonCount
        )
        let provisionalBoundary = Self.provisionalWordBoundary(in: tail)

        let stable = Array(stablePrefix)
        let stableTailCount: Int
        if stable.count >= alignment.consumedCount,
           stable.count <= incoming.count,
           incoming.prefix(stable.count).elementsEqual(stable) {
            stableTailCount = min(
                tail.count,
                stable.count - alignment.consumedCount
            )
        } else {
            stableTailCount = 0
        }
        let confirmedCount = min(
            tail.count,
            max(provisionalBoundary, agreedWordBoundary, stableTailCount)
        )

        if confirmedCount > 0 {
            committed.append(contentsOf: tail.prefix(confirmedCount))
        }

        let unresolved = Array(tail.dropFirst(confirmedCount))
        previousTail = unresolved
        display = String(committed + unresolved)
        return display
    }

    mutating func reset() {
        committed = []
        previousTail = []
        display = ""
    }

    /// Returns the part of a revised full-window hypothesis that is not
    /// already represented by the append-only committed text.
    private func unrepresentedTail(in incoming: [Character]) -> TailAlignment? {
        guard !committed.isEmpty else {
            return TailAlignment(tail: incoming, consumedCount: 0)
        }
        if incoming.starts(with: committed) {
            return TailAlignment(
                tail: Array(incoming.dropFirst(committed.count)),
                consumedCount: committed.count
            )
        }
        if incoming.count >= committed.count,
           Self.matchesIgnoringCaseAndDiacritics(
               Array(incoming.prefix(committed.count)),
               committed
           ) {
            return TailAlignment(
                tail: Array(incoming.dropFirst(committed.count)),
                consumedCount: committed.count
            )
        }

        // Whisper can insert or remove text before the committed boundary.
        // Re-anchor on a sufficiently long committed suffix so that earlier
        // words stay stable without duplicating the newly revised sentence.
        let maximumLength = min(committed.count, Self.maximumAnchorLength)
        guard maximumLength >= Self.minimumAnchorLength else {
            return fallbackAlignment(in: incoming)
        }

        for length in stride(
            from: maximumLength,
            through: Self.minimumAnchorLength,
            by: -1
        ) {
            let anchor = Array(committed.suffix(length))
            guard anchor.contains(where: { !Self.isSeparator($0) }) else { continue }
            if let end = Self.bestMatchEnd(
                of: anchor,
                in: incoming,
                expectedEnd: committed.count
            ) {
                return TailAlignment(
                    tail: Array(incoming.dropFirst(end)),
                    consumedCount: end
                )
            }
        }
        return fallbackAlignment(in: incoming)
    }

    /// Prefer the occurrence nearest the old append boundary. Picking the last
    /// occurrence loses text when the speaker repeats a word or phrase.
    private static func bestMatchEnd(
        of needle: [Character],
        in haystack: [Character],
        expectedEnd: Int
    ) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        var bestEnd: Int?
        var bestDistance = Int.max
        for start in 0...(haystack.count - needle.count) {
            let end = start + needle.count
            guard matchesIgnoringCaseAndDiacritics(
                Array(haystack[start..<end]),
                needle
            ) else { continue }
            let distance = abs(end - expectedEnd)
            if distance < bestDistance {
                bestEnd = end
                bestDistance = distance
            }
        }
        return bestEnd
    }

    private static func matchesIgnoringCaseAndDiacritics(
        _ lhs: [Character],
        _ rhs: [Character]
    ) -> Bool {
        String(lhs).compare(
            String(rhs),
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame
    }

    /// When an earlier word was revised so heavily that no text anchor
    /// survives, align by completed word count. This preserves the append-only
    /// prefix but still lets genuinely new words continue appearing.
    private func fallbackAlignment(in incoming: [Character]) -> TailAlignment? {
        let committedText = String(committed)
        let incomingText = String(incoming)
        let committedWords = Self.wordRanges(in: committedText)
        let incomingWords = Self.wordRanges(in: incomingText)

        if !committedWords.isEmpty, incomingWords.count > committedWords.count {
            var boundary = incomingWords[committedWords.count - 1].upperBound
            while boundary < incomingText.endIndex,
                  Self.isSeparator(incomingText[boundary]) {
                boundary = incomingText.index(after: boundary)
            }
            let consumed = incomingText.distance(
                from: incomingText.startIndex,
                to: boundary
            )
            return TailAlignment(
                tail: Array(incoming.dropFirst(consumed)),
                consumedCount: consumed
            )
        }

        guard committedWords.isEmpty, incoming.count > committed.count else {
            return nil
        }
        return TailAlignment(
            tail: Array(incoming.dropFirst(committed.count)),
            consumedCount: committed.count
        )
    }

    /// Make the first render append-like too: keep only the newest word
    /// tentative instead of waiting several 1.5-second passes before any text
    /// becomes permanent.
    private static func provisionalWordBoundary(in characters: [Character]) -> Int {
        let text = String(characters)
        let words = wordRanges(in: text)
        guard words.count > 1 else { return 0 }

        var boundary = words[words.count - 2].upperBound
        let newestWordStart = words[words.count - 1].lowerBound
        while boundary < newestWordStart, isSeparator(text[boundary]) {
            boundary = text.index(after: boundary)
        }
        return text.distance(from: text.startIndex, to: boundary)
    }

    /// Commit only complete words shared by consecutive hypotheses. Keeping
    /// the current word tentative allows normal decoder corrections without
    /// making the whole sentence flash or move backward.
    private static func confirmedWordBoundary(
        in characters: [Character],
        through agreeingCount: Int
    ) -> Int {
        let limit = min(agreeingCount, characters.count)
        guard limit > 0 else { return 0 }

        let text = String(characters)
        let limitIndex = text.index(text.startIndex, offsetBy: limit)
        var lastCompleteWordEnd: String.Index?
        for range in wordRanges(in: text) {
            if range.upperBound < limitIndex {
                lastCompleteWordEnd = range.upperBound
            } else if range.upperBound == limitIndex,
                      limitIndex < text.endIndex,
                      Self.isSeparator(text[limitIndex]) {
                lastCompleteWordEnd = range.upperBound
            }
        }

        guard var boundary = lastCompleteWordEnd else { return 0 }
        while boundary < limitIndex, Self.isSeparator(text[boundary]) {
            boundary = text.index(after: boundary)
        }
        return text.distance(from: text.startIndex, to: boundary)
    }

    private static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .substringNotRequired]
        ) { _, range, _, _ in
            ranges.append(range)
        }
        return ranges
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character.isWhitespace || character.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0)
                || CharacterSet.symbols.contains($0)
        }
    }
}

struct GuidanceTestSheet: View {
    let engine: SpeechEngine

    private struct TextWord {
        var comparison: String
        var endIndex: String.Index
    }

    @Environment(\.dismiss) private var dismiss
    @State private var dictation = DictationManager()
    @State private var completedTranscript = ""
    @State private var currentTranscript = ""
    @State private var localAccumulator = LocalTranscriptAccumulator()
    @State private var trimLocalWindowOverlap = false
    @State private var didStart = false
    @State private var isDismissingAfterFinalization = false

    private var isActive: Bool {
        dictation.isStarting || dictation.isRecording
    }

    private var transcript: String {
        Self.joinedText(completedTranscript, currentTranscript)
    }

    private var statusTitle: String {
        if dictation.error != nil { return "Couldn't Listen" }
        if dictation.isFinalizing { return "Finishing…" }
        if dictation.isStarting {
            return engine == .local ? "Loading the Model…" : "Getting Ready…"
        }
        if dictation.isRecording { return "Say Something" }
        return "Listening Stopped"
    }

    private var statusMessage: String {
        if let error = dictation.error { return error }
        if dictation.isFinalizing {
            return "Writing the last words from the local model."
        }
        if dictation.isRecording {
            return "Speak normally. Textream will write what it hears below."
        }
        if dictation.isStarting {
            return engine == .local
                ? "The first start can take a moment while the model loads."
                : "Starting Apple Speech and the selected microphone."
        }
        return "Start listening to try the guidance engine again."
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 52, height: 52)

                    Image(systemName: dictation.isRecording ? "mic.fill" : "mic")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(dictation.error == nil ? Color.accentColor : Color.red)
                }

                VStack(spacing: 5) {
                    Text(statusTitle)
                        .font(.title3.weight(.semibold))

                    Text(statusMessage)
                        .font(.callout)
                        .foregroundStyle(dictation.error == nil ? .secondary : Color.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                AudioWaveformView(
                    levels: dictation.audioLevels,
                    color: dictation.isRecording ? .accentColor : .secondary
                )
                .frame(height: 34)
                .opacity(dictation.error == nil ? 1 : 0.45)

                GroupBox("Transcription") {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(transcript.isEmpty ? "Your words will appear here." : transcript)
                                .font(.body)
                                .foregroundStyle(transcript.isEmpty ? .tertiary : .primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(.vertical, 4)

                            Color.clear
                                .frame(height: 1)
                                .id("transcript-end")
                        }
                        .onChange(of: transcript) { _, _ in
                            proxy.scrollTo("transcript-end", anchor: .bottom)
                        }
                    }
                    .frame(height: 88)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Label(
                    engine.label,
                    systemImage: engine == .local ? "cpu" : "apple.logo"
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                Spacer()

                Button(
                    dictation.isFinalizing
                        ? "Finishing…"
                        : (isActive ? "Stop Listening" : "Listen Again")
                ) {
                    if dictation.isFinalizing {
                        return
                    } else if isActive {
                        stopListening()
                    } else {
                        startListening(resetTranscript: true)
                    }
                }
                .disabled(dictation.isFinalizing)

                Button("Done") {
                    stopAndDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(dictation.isFinalizing || isDismissingAfterFinalization)
            }
            .padding(12)
        }
        .frame(width: 480, height: 390)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            guard !didStart else { return }
            didStart = true
            startListening(resetTranscript: true)
        }
        .onDisappear {
            tearDown()
        }
    }

    private func startListening(resetTranscript: Bool) {
        dictation.stop()
        if resetTranscript {
            completedTranscript = ""
            currentTranscript = ""
            resetLocalTranscriptTracking()
        }

        dictation.onNewSegment = {
            if engine == .local {
                commitLocalSegment(hasWindowOverlap: false)
            } else {
                commitCurrentSegment()
            }
        }
        dictation.onLocalWindowRollover = {
            commitLocalSegment(hasWindowOverlap: true)
        }
        dictation.onTextUpdate = { text in
            if engine == .apple {
                currentTranscript = text
            }
        }
        dictation.onLocalTextUpdate = { text, stablePrefix, windowOverlapPrefix in
            updateLocalTranscript(
                with: text,
                stablePrefix: stablePrefix,
                windowOverlapPrefix: windowOverlapPrefix
            )
        }
        dictation.start(engine: engine)
    }

    /// Local engines emit a complete, revised hypothesis on each inference
    /// pass. Keep a confirmed prefix and only replace the short unfinished
    /// tail, so the visible transcript grows naturally.
    private func updateLocalTranscript(
        with text: String,
        stablePrefix: String,
        windowOverlapPrefix: String?
    ) {
        var hypothesis = text
        var confirmedPrefix = stablePrefix
        if trimLocalWindowOverlap {
            hypothesis = removingWindowOverlap(
                from: text,
                expected: windowOverlapPrefix
            )
            confirmedPrefix = removingWindowOverlap(
                from: stablePrefix,
                expected: windowOverlapPrefix
            )
            guard !hypothesis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                currentTranscript = ""
                return
            }
        }
        currentTranscript = localAccumulator.update(
            with: hypothesis,
            stablePrefix: confirmedPrefix
        )
    }

    private func commitLocalSegment(hasWindowOverlap: Bool) {
        appendCompleted(currentTranscript)
        currentTranscript = ""
        localAccumulator.reset()
        // Whisper keeps a short audio overlap between windows. Remove the
        // matching words from the next hypothesis instead of showing them twice.
        trimLocalWindowOverlap = hasWindowOverlap
    }

    private func stopListening() {
        if engine == .local {
            dictation.stopAndFinalizeLocal {
                appendCompleted(currentTranscript)
                currentTranscript = ""
                resetLocalTranscriptTracking()
            }
        } else {
            commitCurrentSegment()
            dictation.stop()
        }
    }

    private func commitCurrentSegment() {
        let segment = currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segment.isEmpty else { return }
        appendCompleted(segment)
        currentTranscript = ""
    }

    private func appendCompleted(_ text: String) {
        let addition = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addition.isEmpty else { return }
        completedTranscript = Self.joinedText(completedTranscript, addition)
    }

    private func resetLocalTranscriptTracking() {
        localAccumulator.reset()
        trimLocalWindowOverlap = false
    }

    private func removingWindowOverlap(from text: String, expected: String?) -> String {
        guard let expected else {
            return removingRepeatedWindowPrefix(from: text)
        }
        // Word timestamps were requested and confirm that the carried audio
        // produced no text. Preserve a repeated first word after that silence.
        guard !expected.isEmpty else { return text }

        // The engine derives this prefix from word timestamps in the new
        // window, so only remove the complete prefix. A partial character or
        // word match can erase a genuinely repeated word after the rollover.
        let exactPrefix = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        if !exactPrefix.isEmpty, text.hasPrefix(exactPrefix) {
            return String(text.dropFirst(exactPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let expectedWords = Self.words(in: exactPrefix)
        let incomingWords = Self.words(in: text)
        if !expectedWords.isEmpty,
           incomingWords.count >= expectedWords.count,
           expectedWords.map(\.comparison)
               == incomingWords.prefix(expectedWords.count).map(\.comparison) {
            let boundary = incomingWords[expectedWords.count - 1].endIndex
            return String(text[boundary...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Timestamp metadata was available but did not match the displayed
        // prefix. Keep the text intact rather than risking data loss.
        return text
    }

    private func removingRepeatedWindowPrefix(from text: String) -> String {
        let existing = Self.words(in: completedTranscript)
        let incoming = Self.words(in: text)
        let maximumWordOverlap = min(min(existing.count, incoming.count), 12)
        guard maximumWordOverlap > 0 else { return text }

        // Prefer the shortest valid overlap. If the speaker intentionally
        // repeats the same word immediately after the one-second audio overlap,
        // a longest-match strategy would erase the newly spoken repetition.
        for count in 1...maximumWordOverlap {
            let existingSuffix = existing.suffix(count).map(\.comparison)
            let newPrefix = incoming.prefix(count).map(\.comparison)
            if existingSuffix == newPrefix {
                let boundary = incoming[count - 1].endIndex
                return String(text[boundary...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    private nonisolated static func words(in text: String) -> [TextWord] {
        var words: [TextWord] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords]
        ) { substring, range, _, _ in
            guard let substring else { return }
            words.append(
                TextWord(
                    comparison: comparisonWord(substring),
                    endIndex: range.upperBound
                )
            )
        }
        return words
    }

    private nonisolated static func comparisonWord(_ word: String) -> String {
        let normalized = word
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
            .lowercased()
        return normalized.isEmpty ? word.lowercased() : normalized
    }

    private nonisolated static func joinedText(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }
        guard let last = left.last, let first = right.first else { return left + right }

        let needsSpace = !isNoSpaceScript(last)
            && !isNoSpaceScript(first)
            && !attachesToPrevious(first)
            && !"([{“‘".contains(last)
        return left + (needsSpace ? " " : "") + right
    }

    private nonisolated static func attachesToPrevious(_ character: Character) -> Bool {
        ".,!?;:%…)]}»”’、。！？；：）」』】》％".contains(character)
    }

    /// Scripts that normally join neighboring segments without inserting an
    /// ASCII space. Latin, Cyrillic, Arabic, and similar scripts keep spaces.
    private nonisolated static func isNoSpaceScript(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0E00...0x0E7F,       // Thai
                 0x3040...0x30FF,       // Hiragana + Katakana
                 0x3400...0x4DBF,       // CJK Extension A
                 0x4E00...0x9FFF,       // CJK Unified Ideographs
                 0xF900...0xFAFF,       // CJK compatibility ideographs
                 0x20000...0x2FA1F:     // CJK extensions
                return true
            default:
                return false
            }
        }
    }

    private func stopAndDismiss() {
        guard !isDismissingAfterFinalization else { return }
        if engine == .local, isActive {
            isDismissingAfterFinalization = true
            dictation.stopAndFinalizeLocal {
                dismiss()
            }
        } else {
            dismiss()
        }
    }

    private func tearDown() {
        dictation.stop()
        dictation.onTextUpdate = nil
        dictation.onLocalTextUpdate = nil
        dictation.onNewSegment = nil
        dictation.onLocalWindowRollover = nil
    }
}
