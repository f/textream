import Foundation

enum MarkdownScriptParser {
    /// Converts Markdown (or plain text) into teleprompter pages.
    static func parse(_ source: String, isPlainText: Bool = false) -> [String] {
        let text = normalise(source)
        if isPlainText {
            return splitPlain(text)
        }
        var lines = text.components(separatedBy: "\n")
        lines = dropFrontmatter(lines)
        lines = dropFencedCode(lines)
        let withoutComments = dropComments(lines.joined(separator: "\n"))
        let body = dropLeadingDateLine(withoutComments.components(separatedBy: "\n"))
        return dropReferencesFooter(buildPages(body))
    }

    // MARK: - Regexes

    private static func rx(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Patterns are compile-time constants; a failure is a programmer error.
        return try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let htmlComment = rx("<!--.*?-->", .dotMatchesLineSeparators)
    private static let obsidianComment = rx("%%.*?%%", .dotMatchesLineSeparators)
    private static let pageBreak = rx("^ {0,3}([-*_])(?:[ \\t]*\\1){2,}[ \\t]*$")
    private static let heading = rx("^ {0,3}(#{1,6})[ \\t]+(.*)$")
    private static let closingHashes = rx("[ \\t]+#+[ \\t]*$")
    private static let footnoteDef = rx("^\\[\\^[^\\]]+\\]:")
    private static let metadataLine = rx("^\\s*(?:Tags?|Status)\\s*:.*$", .caseInsensitive)
    private static let hashtagOnlyLine = rx("^\\s*(?:[A-Za-z ]{1,20}:\\s*)?(?:#[A-Za-z][\\w/-]*\\s*)+$")
    private static let linkDefinition = rx("^\\s*\\[[^\\]]+\\]:\\s*\\S+.*$")
    private static let leadingDate = rx(
        "^\\s*(?:#{1,6}\\s+)?\\d{1,4}[-/.]\\d{1,2}[-/.]\\d{1,4}(?:[ T]+\\d{1,2}:\\d{2}(?::\\d{2})?)?\\s*$")
    private static let looseTableSeparator = rx("^\\s*:?-{3,}:?(?:\\s*\\|\\s*:?-{3,}:?)+\\s*\\|?\\s*$")
    private static let tableSeparator = rx("^\\|?[\\s:\\-|]+\\|?$")
    private static let blockquote = rx("^\\s*(>\\s?)+")
    private static let callout = rx("^\\[![A-Za-z-]+\\][+-]?\\s*")
    private static let taskMarker = rx("^\\s*[-*+]\\s+\\[[ xX]\\]\\s+")
    private static let listMarker = rx("^\\s*(?:[-*+]|\\d{1,3}[.)])\\s+")
    private static let wikilink = rx("\\[\\[([^\\]|#]+)(?:#[^\\]|]*)?(?:\\|([^\\]]+))?\\]\\]")
    private static let spaces = rx("[ \\t]+")

    /// Reference-style images, reference links and empty links, applied before inline links.
    private static let referenceRules: [(NSRegularExpression, String)] = [
        (rx("!\\[[^\\]]*\\]\\[[^\\]]*\\]"), ""),
        (rx("\\[([^\\]]+)\\]\\[[^\\]]*\\]"), "$1"),
        (rx("\\[\\]\\([^)]*\\)"), ""),
        (rx("\\[\\]\\[[^\\]]*\\]"), ""),
    ]

    /// A level 1-2 heading only starts a new page once the current one has this many words; prevents tiny teleprompter pages.
    private static let minPageWords = 40

    private static let br = rx("<br\\s*/?>", .caseInsensitive)

    /// Simple replacements applied in order, each with a `$1`-style template.
    private static let inlineRules: [(NSRegularExpression, String)] = [
        (rx("!\\[[^\\]]*\\]\\([^)]*\\)"), ""),
        (rx("!\\[\\[[^\\]]*\\]\\]"), ""),
        // wikilinks are handled separately, between embeds and links
        (rx("\\[((?:[^\\[\\]]|\\[[^\\]]*\\])+)\\]\\([^)]*\\)"), "$1"),
        (rx("\\[\\^[^\\]]+\\]"), ""),
        (rx("</?[A-Za-z][^>]*>"), ""),
        (rx("\\*\\*(.+?)\\*\\*"), "$1"),
        (rx("(?<=\\w)\\*\\*|\\*\\*(?=\\w)"), ""),
        (rx("~~(.+?)~~"), "$1"),
        (rx("==(?=[^\\s=])(.+?)(?<=[^\\s=])=="), "$1"),
        (rx("(?<![A-Za-z0-9_])__(.+?)__(?![A-Za-z0-9_])"), "$1"),
        (rx("(?<![A-Za-z0-9*])\\*(?!\\s)(.+?)(?<![\\s*])\\*(?![A-Za-z0-9*])"), "$1"),
        (rx("(?<![A-Za-z0-9_])_(?!\\s)(.+?)(?<![\\s_])_(?![A-Za-z0-9_])"), "$1"),
        (rx("`([^`]+)`"), "$1"),
        (rx("[ \\t]+#[A-Za-z][\\w/-]*(?=[.,;:!?])"), ""),
        (rx("(?<![\\w&/#])#[A-Za-z][\\w/-]*"), ""),
    ]

    // MARK: - Stages

    private static func normalise(_ source: String) -> String {
        var s = source
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "\r", with: "\n")
        return s
    }

    private static func splitPlain(_ text: String) -> [String] {
        var pages: [String] = []
        var current: [String] = []
        func flush() {
            let page = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !page.isEmpty { pages.append(page) }
            current = []
        }
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                flush()
            } else {
                current.append(line)
            }
        }
        flush()
        return pages
    }

    private static func dropFrontmatter(_ lines: [String]) -> [String] {
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return lines }
        for i in 1..<max(lines.count, 1) {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t == "---" || t == "..." {
                let body = lines[1..<i]
                return body.allSatisfy(looksLikeYAML) ? Array(lines[(i + 1)...]) : lines
            }
        }
        return lines
    }

    private static let yamlLine = rx("^(?:\\s*#.*|[A-Za-z0-9_][A-Za-z0-9_ .-]*:(?:\\s.*)?|\\s*-\\s.*|\\s+\\S.*)$")

    private static func looksLikeYAML(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty || matches(yamlLine, line)
    }

    private static func fenceMarker(_ line: String) -> String? {
        var idx = line.startIndex
        var indent = 0
        while idx < line.endIndex, line[idx] == " ", indent < 3 {
            idx = line.index(after: idx)
            indent += 1
        }
        let rest = line[idx...]
        if rest.hasPrefix("```") { return "```" }
        if rest.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func dropFencedCode(_ lines: [String]) -> [String] {
        var out: [String] = []
        var openFence: String?
        for line in lines {
            if let fence = openFence {
                if fenceMarker(line) == fence { openFence = nil }
                continue
            }
            if let fence = fenceMarker(line) {
                openFence = fence
                continue
            }
            out.append(line)
        }
        return out
    }

    private static func dropComments(_ text: String) -> String {
        var s = replace(htmlComment, in: text, with: "")
        s = replace(obsidianComment, in: s, with: "")
        return s
    }

    private static func dropLeadingDateLine(_ lines: [String]) -> [String] {
        guard let i = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              matches(leadingDate, lines[i]) else { return lines }
        var out = lines
        out.remove(at: i)
        return out
    }

    private static func dropReferencesFooter(_ pages: [String]) -> [String] {
        guard pages.count > 1, let last = pages.last else { return pages }
        var first = (last.components(separatedBy: "\n").first ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        if first.hasSuffix(":") { first.removeLast() }
        return first == "references" ? Array(pages.dropLast()) : pages
    }

    private static func wordCount(_ lines: [String]) -> Int {
        lines.reduce(0) { $0 + $1.split(whereSeparator: { $0.isWhitespace }).count }
    }

    private static func buildPages(_ lines: [String]) -> [String] {
        var pages: [String] = []
        var current: [String] = []
        // True once the current page holds a non-heading, non-empty line.
        var currentHasBody = false
        var inTable = false
        var lastPageHadBody = false

        func flush() {
            let hadBody = currentHasBody
            currentHasBody = false
            var page = current.joined(separator: "\n")
            current = []
            while page.contains("\n\n\n") {
                page = page.replacingOccurrences(of: "\n\n\n", with: "\n\n")
            }
            page = page.trimmingCharacters(in: .whitespacesAndNewlines)
            if !page.isEmpty {
                pages.append(page)
                lastPageHadBody = hadBody
            }
        }

        func joinCells(_ s: String) -> String {
            s.components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        // A page break after a heading-only page keeps those headings for the next page.
        func breakPage() {
            if currentHasBody { flush() }
        }

        for line in lines {
            if matches(pageBreak, line) {
                breakPage()
                continue
            }
            if let m = firstMatch(heading, line) {
                var title = substring(line, m.range(at: 2))
                title = replace(closingHashes, in: title, with: "")
                let cleaned = stripInline(title)
                var key = cleaned.trimmingCharacters(in: .whitespaces).lowercased()
                if key.hasSuffix(":") { key.removeLast() }
                // A References heading of any level always starts its own page so the footer can be dropped.
                if key == "references"
                    || (substring(line, m.range(at: 1)).count <= 2 && wordCount(current) >= minPageWords) {
                    breakPage()
                }
                current.append(cleaned)
                continue
            }
            if matches(footnoteDef, line) || matches(linkDefinition, line) { continue }
            if matches(metadataLine, line) || matches(hashtagOnlyLine, line) { continue }

            if matches(looseTableSeparator, line) {
                if let prev = current.last, prev.contains("|") {
                    current[current.count - 1] = joinCells(prev)
                    inTable = true
                }
                continue
            }

            var text = line
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.contains("|") { inTable = false }
            if inTable && !trimmed.hasPrefix("|") {
                text = joinCells(trimmed)
            } else if trimmed.hasPrefix("|") {
                if trimmed.contains("-") && matches(tableSeparator, trimmed) { continue }
                text = trimmed.components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            text = replace(blockquote, in: text, with: "")
            text = replace(callout, in: text, with: "")
            if matches(taskMarker, text) {
                text = replace(taskMarker, in: text, with: "")
            } else {
                text = replace(listMarker, in: text, with: "")
            }
            let stripped = stripInline(text)
            if stripped.isEmpty {
                // Blank lines before any body text are not kept; they would split a heading from its page.
                if currentHasBody { current.append(stripped) }
                continue
            }
            currentHasBody = true
            current.append(stripped)
        }
        flush()
        if pages.count > 1 && !lastPageHadBody { pages.removeLast() }
        return pages
    }

    private static func stripInline(_ input: String) -> String {
        var s = replace(br, in: input, with: "\n")
        // images and embeds first
        s = replace(inlineRules[0].0, in: s, with: inlineRules[0].1)
        s = replace(inlineRules[1].0, in: s, with: inlineRules[1].1)
        for (regex, template) in referenceRules {
            s = replace(regex, in: s, with: template)
        }
        s = replaceWikilinks(s)
        for (regex, template) in inlineRules.dropFirst(2) {
            s = replace(regex, in: s, with: template)
        }
        s = replace(spaces, in: s, with: " ")
        return s.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
    }

    private static func replaceWikilinks(_ s: String) -> String {
        let ns = s as NSString
        let found = wikilink.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !found.isEmpty else { return s }
        var result = ""
        var last = 0
        for m in found {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let aliasRange = m.range(at: 2)
            if aliasRange.location != NSNotFound {
                result += ns.substring(with: aliasRange)
            } else {
                result += ns.substring(with: m.range(at: 1))
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    // MARK: - Helpers

    private static func replace(_ regex: NSRegularExpression, in s: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }

    private static func firstMatch(_ regex: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    private static func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
        firstMatch(regex, s) != nil
    }

    private static func substring(_ s: String, _ range: NSRange) -> String {
        (s as NSString).substring(with: range)
    }
}
