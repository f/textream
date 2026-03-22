import CoreML
import Foundation

class SentenceEmbedder {
    private let model: MLModel
    private let tokenizer: WordPieceTokenizer
    private let maxLength: Int = 128
    private let embeddingDim: Int = 384

    init?() {
        guard let modelURL = Bundle.main.url(forResource: "MiniLM", withExtension: "mlmodelc"),
              let vocabURL = Bundle.main.url(forResource: "vocab", withExtension: "txt") else {
            return nil
        }
        guard let model = try? MLModel(contentsOf: modelURL),
              let tokenizer = WordPieceTokenizer(vocabURL: vocabURL, maxLength: 128) else {
            return nil
        }
        self.model = model
        self.tokenizer = tokenizer
    }

    /// Embed a single string. Returns L2-normalized 384-dim vector.
    func embed(_ text: String) -> [Float]? {
        let tokens = tokenizer.tokenize(text)

        guard let inputIdsArray = try? MLMultiArray(shape: [1, NSNumber(value: maxLength)], dataType: .int32),
              let attentionMaskArray = try? MLMultiArray(shape: [1, NSNumber(value: maxLength)], dataType: .int32) else {
            return nil
        }

        for i in 0..<maxLength {
            inputIdsArray[i] = NSNumber(value: tokens.inputIds[i])
            attentionMaskArray[i] = NSNumber(value: tokens.attentionMask[i])
        }

        let input = try? MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputIdsArray),
            "attention_mask": MLFeatureValue(multiArray: attentionMaskArray)
        ])

        guard let input,
              let output = try? model.prediction(from: input),
              let hiddenState = output.featureValue(for: "last_hidden_state")?.multiArrayValue else {
            return nil
        }

        // Mean pooling: average over non-padding tokens
        return meanPoolAndNormalize(hiddenState: hiddenState, attentionMask: tokens.attentionMask)
    }

    /// Embed a batch of strings. Returns array of L2-normalized 384-dim vectors.
    func embedBatch(_ texts: [String]) -> [[Float]?] {
        // CoreML batch prediction is complex; for our segment counts (~100)
        // sequential embedding is fast enough (~100-200ms total)
        return texts.map { embed($0) }
    }

    private func meanPoolAndNormalize(hiddenState: MLMultiArray, attentionMask: [Int32]) -> [Float] {
        // hiddenState shape: [1, maxLength, embeddingDim]
        var pooled = [Float](repeating: 0, count: embeddingDim)
        var tokenCount: Float = 0

        for t in 0..<maxLength {
            guard attentionMask[t] == 1 else { continue }
            tokenCount += 1
            for d in 0..<embeddingDim {
                let idx = t * embeddingDim + d
                pooled[d] += hiddenState[idx].floatValue
            }
        }

        // Average
        if tokenCount > 0 {
            for d in 0..<embeddingDim {
                pooled[d] /= tokenCount
            }
        }

        // L2 normalize
        var norm: Float = 0
        for d in 0..<embeddingDim {
            norm += pooled[d] * pooled[d]
        }
        norm = sqrt(norm)
        if norm > 0 {
            for d in 0..<embeddingDim {
                pooled[d] /= norm
            }
        }

        return pooled
    }
}
