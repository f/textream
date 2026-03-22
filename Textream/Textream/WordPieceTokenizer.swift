import Foundation

class WordPieceTokenizer {
    private let vocab: [String: Int]
    private let unkTokenId: Int
    private let clsTokenId: Int
    private let sepTokenId: Int
    private let padTokenId: Int
    private let maxLength: Int

    init?(vocabURL: URL, maxLength: Int = 128) {
        guard let content = try? String(contentsOf: vocabURL, encoding: .utf8) else { return nil }
        let tokens = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var vocab: [String: Int] = [:]
        for (i, token) in tokens.enumerated() {
            vocab[token] = i
        }
        self.vocab = vocab
        self.unkTokenId = vocab["[UNK]"] ?? 0
        self.clsTokenId = vocab["[CLS]"] ?? 101
        self.sepTokenId = vocab["[SEP]"] ?? 102
        self.padTokenId = vocab["[PAD]"] ?? 0
        self.maxLength = maxLength
    }

    struct TokenizedInput {
        let inputIds: [Int32]
        let attentionMask: [Int32]
    }

    func tokenize(_ text: String) -> TokenizedInput {
        let lowered = text.lowercased()
        let words = splitOnPunctuation(lowered)

        var tokenIds: [Int] = [clsTokenId]

        for word in words {
            let subTokens = wordPieceTokenize(word)
            tokenIds.append(contentsOf: subTokens)
        }

        tokenIds.append(sepTokenId)

        // Truncate if needed (keep CLS and SEP)
        if tokenIds.count > maxLength {
            tokenIds = Array(tokenIds.prefix(maxLength - 1)) + [sepTokenId]
        }

        // Pad
        let attentionMask = Array(repeating: Int32(1), count: tokenIds.count)
            + Array(repeating: Int32(0), count: max(0, maxLength - tokenIds.count))
        let paddedIds = tokenIds.map { Int32($0) }
            + Array(repeating: Int32(padTokenId), count: max(0, maxLength - tokenIds.count))

        return TokenizedInput(
            inputIds: paddedIds,
            attentionMask: attentionMask
        )
    }

    private func splitOnPunctuation(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for char in text {
            if char.isWhitespace {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else if char.isPunctuation || char.isSymbol {
                if !current.isEmpty { words.append(current) }
                words.append(String(char))
                current = ""
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private func wordPieceTokenize(_ word: String) -> [Int] {
        var tokens: [Int] = []
        var start = word.startIndex

        while start < word.endIndex {
            var end = word.endIndex
            var found = false

            while start < end {
                let substr: String
                if start == word.startIndex {
                    substr = String(word[start..<end])
                } else {
                    substr = "##" + String(word[start..<end])
                }

                if let id = vocab[substr] {
                    tokens.append(id)
                    start = end
                    found = true
                    break
                }
                end = word.index(before: end)
            }

            if !found {
                tokens.append(unkTokenId)
                start = word.index(after: start)
            }
        }
        return tokens
    }
}
