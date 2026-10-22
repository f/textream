import AppKit
import CoreText

// SpeechScrollView only needs these two cases from the application settings.
// The runner compiles the production layout without the app or its services.
enum ReadingPosition { case centered, nearTop }

extension WordFlowLayout {
    func layoutForTest() -> ([WordItem], [[WordItem]], [Int]) { cachedLayout() }
}

@main
@MainActor
struct PrompterLayoutTests {
    private static var failures = 0
    private static var checks = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let fontURL = root.appendingPathComponent("Textream/Textream/Fonts/OpenDyslexic3-Regular.ttf")
        CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
        var fonts = [
            NSFont.systemFont(ofSize: 14, weight: .semibold),
            NSFont.systemFont(ofSize: 20, weight: .semibold),
            NSFont.systemFont(ofSize: 24, weight: .semibold),
            NSFont.monospacedSystemFont(ofSize: 20, weight: .semibold)
        ]
        if let dyslexic = NSFont(name: "OpenDyslexic3", size: 20) { fonts.append(dyslexic) }
        let scripts = [
            "数字测试2026年1234元5678人9012件。金额1234.56元，增长12.34%，时间2026-10-20。",
            "那一年他 36 歲，搬到新的城市，而且換過三份工作。",
            "收入１２３４元 [pause] English 1,234.56 next [look at camera]",
            "Hello 2026, a short English script with 1234.56 and 12.34%.",
            "مرحبا 1234 بالعالم",
            "שלום 2026 עולם"
        ]
        var measuredWidths: [String: CGFloat] = [:]
        for font in fonts {
            for script in scripts {
                let words = splitTextIntoWords(script)
                for width: CGFloat in [246, 278, 310, 340, 468] {
                    let layout = WordFlowLayout(words: words, highlightedCharCount: 0,
                                                font: font, containerWidth: width)
                    let (items, lines, _) = layout.layoutForTest()
                    check(lines.flatMap { $0 }.map(\.word) == words,
                          "line construction lost content: \(font.fontName), \(width)")
                    var offset = 0
                    for item in items {
                        check(item.charOffset == offset, "character offsets changed")
                        offset += item.word.count + 1
                    }
                    for line in lines {
                        var actualWidth: CGFloat = 0
                        for item in line {
                            let key = "\(font.fontName)|\(font.pointSize)|\(item.isAnnotation)|\(item.word)"
                            let measured: CGFloat
                            if let cached = measuredWidths[key] {
                                measured = cached
                            } else {
                                let text = Text(item.word + " ")
                                    .font(item.isAnnotation ? Font(font).italic() : Font(font))
                                measured = NSHostingView(rootView: text.fixedSize()).fittingSize.width
                                measuredWidths[key] = measured
                            }
                            actualWidth += measured
                        }
                        // Overlong single tokens already have their own line;
                        // this change only prevents compression of words that fit.
                        if line.count > 1 || actualWidth <= width {
                            check(actualWidth <= width,
                                  "packed row exceeds \(width): \(actualWidth), \(font.fontName), \(line.map(\.word))")
                        }
                    }
                }
            }
        }
        let longNumber = String(repeating: "1234567890", count: 12)
        let words = ["before", longNumber, "after"]
        let (_, longLines, _) = WordFlowLayout(words: words, highlightedCharCount: 0,
            font: fonts[1], containerWidth: 246).layoutForTest()
        check(longLines.contains { $0.map(\.word) == [longNumber] }, "overlong number did not get its own row")

        let first = WordFlowLayout(words: ["中", "旧", "文"], highlightedCharCount: 0,
                                   font: fonts[1], containerWidth: 246).layoutForTest()
        let edited = WordFlowLayout(words: ["中", "新", "文"], highlightedCharCount: 0,
                                    font: fonts[1], containerWidth: 246).layoutForTest()
        check(first.0[1].word == "旧", "initial script not laid out")
        check(edited.0[1].word == "新", "same-length middle edit reused stale words")
        let paragraph = WordFlowLayout(words: ["中", "新", "文"], highlightedCharCount: 0,
            font: fonts[1], paragraphBreakBeforeWordIndices: [1], containerWidth: 246)
            .layoutForTest()
        check(paragraph.1.count == 2, "paragraph edit reused stale lines")
        check(paragraph.2.last == 1, "paragraph metadata not updated")
        let highlighted = WordFlowLayout(words: ["中", "新", "文"], highlightedCharCount: 2,
            font: fonts[1], paragraphBreakBeforeWordIndices: [1], containerWidth: 246)
            .layoutForTest()
        check(highlighted.1.map { $0.map(\.word) } == paragraph.1.map { $0.map(\.word) },
              "highlight-only update changed line layout")
        print("\(checks) checks; \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
