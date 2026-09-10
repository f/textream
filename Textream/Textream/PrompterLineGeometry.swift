import Foundation

/// Row coordinates stay available even when only the visible text is rendered.
struct PrompterLineGeometry {
    let rowHeight: CGFloat
    let lineSpacing: CGFloat
    let paragraphExtraSpacing: CGFloat
    let paragraphPrefixCounts: [Int]

    var lineAdvance: CGFloat { rowHeight + lineSpacing }

    func top(of line: Int) -> CGFloat {
        CGFloat(line) * lineAdvance
            + CGFloat(paragraphPrefixCounts[line]) * paragraphExtraSpacing
    }

    func height(of line: Int) -> CGFloat {
        let beginsParagraph = paragraphPrefixCounts[line + 1] > paragraphPrefixCounts[line]
        return rowHeight + (beginsParagraph ? paragraphExtraSpacing : 0)
    }

    func fillingMissingPositions<Word: Identifiable>(
        measured: [Int: CGFloat],
        lines: [[Word]]
    ) -> [Int: CGFloat] where Word.ID == Int {
        var positions = measured
        for (lineIndex, line) in lines.enumerated() {
            let center = top(of: lineIndex) + height(of: lineIndex) - rowHeight * 0.5
            for word in line where positions[word.id] == nil {
                positions[word.id] = center
            }
        }
        return positions
    }
}
