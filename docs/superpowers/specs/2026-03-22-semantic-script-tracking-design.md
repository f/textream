# Semantic Script Tracking — Design Spec

## Problem

Textream's script position tracker uses fuzzy character-level and word-level matching against the script. This fails when the speaker paraphrases, skips sentences, ad-libs transitions, or goes back to re-read an earlier section. The current matcher also only moves forward — it cannot recover when the speaker returns to a previous position.

## Solution

Replace the fuzzy matching system with embedding-based bidirectional semantic search. A lightweight sentence embedding model (all-MiniLM-L6-v2 via CoreML) compares transcribed speech against script segments using cosine similarity. The matcher supports forward progression, backward recovery, and a "hold" state for off-script speech.

## Architecture: ScriptTracker Protocol

Extract matching logic from `SpeechRecognizer` into a `ScriptTracker` protocol with two implementations:

- **`SemanticScriptTracker`** — new embedding-based bidirectional matcher (primary)
- **`FuzzyScriptTracker`** — existing char/word matching extracted verbatim (fallback)

### Protocol & Types

```swift
enum MatchDirection {
    case forward
    case backward
    case hold
}

struct MatchResult {
    let charOffset: Int
    let confidence: Float     // 0.0–1.0 cosine similarity
    let direction: MatchDirection
}

protocol ScriptTracker {
    func loadScript(_ text: String)
    func match(spoken: String) -> MatchResult
    func jumpTo(charOffset: Int)
    func reset()
}
```

`SpeechRecognizer` owns a `ScriptTracker`, calls `loadScript()` when the script is set, and calls `match(spoken:)` from the recognition callback.

## Script Segmentation

At `loadScript()` time, the script is broken into segments using a hybrid approach:

### Segmentation Rules

- Split on sentence boundaries (`.`, `?`, `!`)
- Sentences longer than ~25 words are subdivided at clause boundaries (commas, semicolons, em dashes) or at the 20-word mark if no clause boundary exists
- Consecutive short sentences under ~8 words are merged into one segment
- Segments that are purely annotations (`[like this]`) or emoji-only are excluded from similarity matching

### Segment Structure

```swift
struct ScriptSegment {
    let text: String
    let charRange: Range<Int>  // position in original script
    var embedding: [Float]?    // populated after CoreML inference
}
```

### Pre-embedding

All segments are embedded at load time on a background queue. For a typical 2000-word script (~80-100 segments), all-MiniLM-L6-v2 via CoreML completes in under 200ms on M1.

## Sliding Window & Similarity Search

When `match(spoken:)` is called:

### 1. Embed the Spoken Text

The incoming transcription is embedded via the same CoreML model (~1-2ms per inference).

### 2. Define the Search Window

- Centered on the current matched segment index
- Extends N segments forward and N segments backward (~8-12 segments each direction, calibrated to ~20 seconds of script)
- Clamps to script bounds

### 3. Compute Similarities

Cosine similarity (dot product on L2-normalized vectors) between the spoken embedding and every segment embedding in the window. Find the best match.

### 4. Interpret the Result

```
if bestScore >= forwardThreshold (0.55):
    if bestSegment is ahead of or at current position → forward
    if bestSegment is behind current position:
        if bestScore >= backwardThreshold (0.70) → backward
        else → hold

if bestScore < forwardThreshold → hold
```

**Asymmetric thresholds:** Backward movement requires higher confidence (0.70 vs 0.55) because:
- Forward movement is expected — the speaker usually progresses through the script
- Backward jumps are unusual — false positives cause disruptive scroll jumps
- Short common phrases might partially match earlier segments

These thresholds are starting points and will need tuning.

### 5. Hold Buffer

When in hold state:
- Transcription chunks are buffered with timestamps (wall clock at time of recognition callback)
- Chunks older than 5 seconds are evicted on each new arrival
- On each new chunk, the buffer is concatenated and re-evaluated as a single string
- This catches transitions back to script that span multiple short utterances
- The buffer is cleared on: forward/backward match accepted, `jumpTo()`, `loadScript()`, or `reset()`

## CoreML Model Management

### Model Packaging

- all-MiniLM-L6-v2 converted to CoreML format (`.mlmodelc`) using `coremltools`
- Added to the Xcode project bundle (~80MB)
- Input: token IDs + attention mask
- Output: per-token embeddings (384-dimensional), mean-pooled and L2-normalized

### Tokenizer

A minimal WordPiece tokenizer (~100 lines of Swift) bundled with `vocab.txt`:
- Lowercasing, whitespace/punctuation splitting
- Vocabulary lookup with `[UNK]` fallback
- `##` subword prefix handling

### Inference Wrapper

```swift
class SentenceEmbedder {
    private let model: MLModel
    private let tokenizer: WordPieceTokenizer

    func embed(_ text: String) -> [Float]
    func embedBatch(_ texts: [String]) -> [[Float]]
}
```

Mean pooling across non-padding tokens, then L2 normalization so cosine similarity becomes a dot product.

### Performance Budget

- Script load: ~80-100 segments batch embedded in ~100-200ms (background queue)
- Per-utterance: single embedding ~1-2ms, window search negligible

## Integration with SpeechRecognizer

### What Gets Removed

- `charLevelMatch()`, `wordLevelMatch()`, `isAnnotationWord()`, `isFuzzyMatch()`, `editDistance()`, `normalize()` (~200 lines)
- Properties `matchStartOffset` and `normalizedSource` — no longer needed since the tracker owns positional state

### What Gets Rewritten

`matchCharacters(spoken:)` becomes:

```swift
private func matchCharacters(spoken: String) {
    let result = tracker.match(spoken: spoken)

    switch result.direction {
    case .forward:
        recognizedCharCount = min(result.charOffset, sourceText.count)
    case .backward:
        recognizedCharCount = max(0, min(result.charOffset, sourceText.count))
    case .hold:
        break
    }
}
```

### What Gets Modified

- `jumpTo(charOffset:)` — additionally calls `tracker.jumpTo(charOffset:)` to recenter the sliding window. Remove `matchStartOffset` usage.
- `start(with:)` — calls `tracker.loadScript(text)` which triggers segmentation and background embedding. Note: `start` preprocesses text through `splitTextIntoWords()` which collapses whitespace and removes newlines. The tracker receives this preprocessed `sourceText`, so segmentation uses punctuation-based sentence boundaries (not newlines).
- `resume()` — calls `tracker.jumpTo(charOffset: recognizedCharCount)` to recenter the window after recognition restarts. Remove `matchStartOffset` usage.
- `updateText(_:preservingCharCount:)` — calls `tracker.loadScript()` with the new text and `tracker.jumpTo()` to maintain position. Since Director Mode may call this on every keystroke, `loadScript()` debounces re-embedding internally (300ms delay, cancelling previous pending work).

### Threading & Initialization

- `loadScript()` returns synchronously but kicks off background embedding
- `match(spoken:)` returns `.hold` until embedding is complete — the caller sees no movement until the model is ready
- The `SemanticScriptTracker` uses a serial dispatch queue for embedding work; segment data is only mutated on that queue and read-copied for `match()` calls on main

### Fallback Strategy

`FuzzyScriptTracker` is used automatically if the CoreML model fails to load (missing `.mlmodelc` file, unsupported hardware). `SpeechRecognizer` attempts to create `SemanticScriptTracker` and falls back to `FuzzyScriptTracker` on failure, logging a warning.

### What Stays Unchanged

- All AVAudioEngine / SFSpeechRecognizer setup and lifecycle
- Recognition task callback structure
- `recognizedCharCount` as the published property driving the UI
- Audio level monitoring
- Session generation guards

## File Organization

### New Files

| File | Responsibility |
|------|---------------|
| `ScriptTracker.swift` | Protocol, `MatchResult`, `MatchDirection`, `ScriptSegment` |
| `SemanticScriptTracker.swift` | Segmentation, sliding window, hold buffer, confidence logic |
| `SentenceEmbedder.swift` | CoreML model loading, WordPiece tokenizer, mean pooling |
| `FuzzyScriptTracker.swift` | Existing matching logic extracted, conforming to `ScriptTracker` |

### Modified Files

| File | Change |
|------|--------|
| `SpeechRecognizer.swift` | Remove ~200 lines of matching, add tracker delegation, update `resume()` and `updateText()` |

### Bundle Additions

| Asset | Description |
|-------|-------------|
| `MiniLM.mlmodelc` | CoreML model (~80MB) |
| `vocab.txt` | WordPiece vocabulary (~230KB) |

### Unchanged

MarqueeTextView, TextreamService, ContentView, BrowserServer, NotchSettings, ExternalDisplayController — everything downstream of `recognizedCharCount` is untouched.
