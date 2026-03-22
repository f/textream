import Foundation

class SemanticScriptTracker: ScriptTracker {
    private let embedder: SentenceEmbedder
    private var segments: [ScriptSegment] = []
    private var currentSegmentIndex: Int = 0
    private var isEmbeddingComplete: Bool = false
    private let windowSize: Int = 10  // segments in each direction

    // Confidence thresholds
    private let forwardThreshold: Float = 0.55
    private let backwardThreshold: Float = 0.70

    // Hold buffer
    private var holdBuffer: [(text: String, timestamp: Date)] = []
    private let holdBufferDuration: TimeInterval = 5.0

    // Debounce for updateText
    private var pendingEmbedding: DispatchWorkItem?
    private let embeddingQueue = DispatchQueue(label: "com.textream.embedding", qos: .userInitiated)

    // Thread-safe segment access
    private var embeddedSegments: [ScriptSegment] = []  // read-copy for main thread
    private let segmentLock = NSLock()

    init(embedder: SentenceEmbedder) {
        self.embedder = embedder
    }

    /// Set `immediate: true` for initial script load (no debounce).
    /// Set `immediate: false` for live updateText calls (300ms debounce).
    func loadScript(_ text: String, immediate: Bool = true) {
        // Cancel any pending embedding work
        pendingEmbedding?.cancel()
        pendingEmbedding = nil

        // Segment synchronously
        segments = segment(text)
        currentSegmentIndex = 0
        isEmbeddingComplete = false
        holdBuffer = []

        // Copy segments without embeddings for immediate use
        segmentLock.lock()
        embeddedSegments = segments
        segmentLock.unlock()

        // Embed on background queue (debounced for rapid updateText calls)
        let segmentsToEmbed = segments  // capture by value to avoid race with main thread
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let texts = segmentsToEmbed.filter { !$0.isAnnotation }.map(\.text)
            let embeddings = self.embedder.embedBatch(texts)

            var updated = segmentsToEmbed
            var embIdx = 0
            for i in 0..<updated.count {
                if !updated[i].isAnnotation {
                    updated[i].embedding = embeddings[embIdx]
                    embIdx += 1
                }
            }

            self.segmentLock.lock()
            self.embeddedSegments = updated
            self.segmentLock.unlock()

            DispatchQueue.main.async {
                self.isEmbeddingComplete = true
            }
        }
        pendingEmbedding = work
        if immediate {
            embeddingQueue.async(execute: work)
        } else {
            embeddingQueue.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    // MARK: - Segmentation

    private func segment(_ text: String) -> [ScriptSegment] {
        let sentences = splitIntoSentences(text)
        var result: [ScriptSegment] = []
        var pendingMerge: [(text: String, range: Range<Int>)] = []

        for sentence in sentences {
            let wordCount = sentence.text.split(separator: " ").count
            let isAnnotation = isAnnotationOnly(sentence.text)

            if isAnnotation {
                if !pendingMerge.isEmpty {
                    result.append(flushMerge(&pendingMerge))
                }
                result.append(ScriptSegment(
                    text: sentence.text,
                    charRange: sentence.range,
                    embedding: nil,
                    isAnnotation: true
                ))
            } else if wordCount > 25 {
                if !pendingMerge.isEmpty {
                    result.append(flushMerge(&pendingMerge))
                }
                let subs = subdivide(sentence.text, charStart: sentence.range.lowerBound)
                result.append(contentsOf: subs)
            } else if wordCount < 8 {
                pendingMerge.append((text: sentence.text, range: sentence.range))
                let totalWords = pendingMerge.reduce(0) { $0 + $1.text.split(separator: " ").count }
                if totalWords >= 8 {
                    result.append(flushMerge(&pendingMerge))
                }
            } else {
                if !pendingMerge.isEmpty {
                    result.append(flushMerge(&pendingMerge))
                }
                result.append(ScriptSegment(
                    text: sentence.text,
                    charRange: sentence.range,
                    embedding: nil,
                    isAnnotation: false
                ))
            }
        }

        if !pendingMerge.isEmpty {
            result.append(flushMerge(&pendingMerge))
        }

        return result
    }

    private struct SentenceSpan {
        let text: String
        let range: Range<Int>
    }

    private func splitIntoSentences(_ text: String) -> [SentenceSpan] {
        var results: [SentenceSpan] = []
        var current = ""
        var startIdx = 0

        for (i, char) in text.enumerated() {
            current.append(char)
            if char == "." || char == "?" || char == "!" {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    results.append(SentenceSpan(text: trimmed, range: startIdx..<(i + 1)))
                }
                current = ""
                startIdx = i + 1
            }
        }

        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            results.append(SentenceSpan(text: trimmed, range: startIdx..<text.count))
        }

        return results
    }

    private func subdivide(_ text: String, charStart: Int) -> [ScriptSegment] {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var segments: [ScriptSegment] = []
        var i = 0
        var charOffset = charStart

        while i < words.count {
            var end = min(i + 20, words.count)
            let searchStart = i + 15
            let searchEnd = min(i + 25, words.count)
            for j in searchStart..<max(searchStart, searchEnd) {
                let word = words[j]
                if word.hasSuffix(",") || word.hasSuffix(";") || word.hasSuffix("—") || word.hasSuffix("-") {
                    end = j + 1
                    break
                }
            }
            end = min(end, words.count)

            let chunk = words[i..<end].joined(separator: " ")
            let chunkEnd = charOffset + chunk.count
            segments.append(ScriptSegment(
                text: chunk,
                charRange: charOffset..<chunkEnd,
                embedding: nil,
                isAnnotation: false
            ))
            charOffset = chunkEnd + 1
            i = end
        }

        return segments
    }

    private func flushMerge(_ pending: inout [(text: String, range: Range<Int>)]) -> ScriptSegment {
        let text = pending.map(\.text).joined(separator: " ")
        let range = pending.first!.range.lowerBound..<pending.last!.range.upperBound
        pending.removeAll()
        return ScriptSegment(text: text, charRange: range, embedding: nil, isAnnotation: false)
    }

    private func isAnnotationOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") { return true }
        let stripped = trimmed.filter { $0.isLetter || $0.isNumber }
        return stripped.isEmpty
    }

    // MARK: - Matching

    func match(spoken: String) -> MatchResult {
        guard isEmbeddingComplete else { return .hold }

        segmentLock.lock()
        let segs = embeddedSegments
        segmentLock.unlock()

        guard !segs.isEmpty else { return .hold }

        guard let spokenEmbedding = embedder.embed(spoken) else { return .hold }

        let bufferedText = buildBufferedText(newChunk: spoken)
        let bufferedEmbedding = (bufferedText != spoken) ? embedder.embed(bufferedText) : nil

        let windowStart = max(0, currentSegmentIndex - windowSize)
        let windowEnd = min(segs.count - 1, currentSegmentIndex + windowSize)

        var bestScore: Float = -1
        var bestIndex: Int = currentSegmentIndex

        for i in windowStart...windowEnd {
            guard !segs[i].isAnnotation, let segEmb = segs[i].embedding else { continue }

            let score = dotProduct(spokenEmbedding, segEmb)
            if score > bestScore {
                bestScore = score
                bestIndex = i
            }

            if let buffEmb = bufferedEmbedding {
                let buffScore = dotProduct(buffEmb, segEmb)
                if buffScore > bestScore {
                    bestScore = buffScore
                    bestIndex = i
                }
            }
        }

        let direction: MatchDirection
        if bestScore >= forwardThreshold {
            if bestIndex >= currentSegmentIndex {
                direction = .forward
            } else if bestScore >= backwardThreshold {
                direction = .backward
            } else {
                direction = .hold
            }
        } else {
            direction = .hold
        }

        switch direction {
        case .forward, .backward:
            currentSegmentIndex = bestIndex
            holdBuffer = []
            let charOffset = segs[bestIndex].charRange.upperBound
            return MatchResult(charOffset: charOffset, confidence: bestScore, direction: direction)
        case .hold:
            appendToHoldBuffer(spoken)
            return .hold
        }
    }

    func jumpTo(charOffset: Int) {
        segmentLock.lock()
        let segs = embeddedSegments
        segmentLock.unlock()

        for (i, seg) in segs.enumerated() {
            if seg.charRange.contains(charOffset) || seg.charRange.lowerBound >= charOffset {
                currentSegmentIndex = i
                break
            }
        }
        holdBuffer = []
    }

    func reset() {
        segments = []
        segmentLock.lock()
        embeddedSegments = []
        segmentLock.unlock()
        currentSegmentIndex = 0
        isEmbeddingComplete = false
        holdBuffer = []
        pendingEmbedding?.cancel()
        pendingEmbedding = nil
    }

    // MARK: - Hold Buffer

    private func appendToHoldBuffer(_ text: String) {
        let now = Date()
        holdBuffer.append((text: text, timestamp: now))
        holdBuffer.removeAll { now.timeIntervalSince($0.timestamp) > holdBufferDuration }
    }

    private func buildBufferedText(newChunk: String) -> String {
        let now = Date()
        let recentChunks = holdBuffer.filter { now.timeIntervalSince($0.timestamp) <= holdBufferDuration }
        if recentChunks.isEmpty { return newChunk }
        let buffered = recentChunks.map(\.text).joined(separator: " ")
        return buffered + " " + newChunk
    }

    // MARK: - Vector Math

    /// Cosine similarity for L2-normalized vectors (dot product equivalent).
    private func dotProduct(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var result: Float = 0
        for i in 0..<a.count {
            result += a[i] * b[i]
        }
        return result
    }
}
