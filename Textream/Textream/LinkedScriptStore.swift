import Foundation

enum LinkedScriptError: Error, LocalizedError {
    case bookmarkInvalid
    case unreadable(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .bookmarkInvalid: return "The link to the script file is no longer valid."
        case .unreadable(let reason): return "The script file could not be read: \(reason)"
        case .empty: return "The script file has no readable text."
        }
    }
}

enum LinkedScriptStore {
    static func makeBookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            throw LinkedScriptError.bookmarkInvalid
        }
    }

    static func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            return (url: url, isStale: stale)
        } catch {
            throw LinkedScriptError.bookmarkInvalid
        }
    }

    static func loadPages(from url: URL) throws -> [String] {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // Read file
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LinkedScriptError.unreadable(error.localizedDescription)
        }

        // Decode
        let source: String
        if let utf8 = String(data: data, encoding: .utf8) {
            source = utf8
        } else if data.count >= 2 && ((data[0] == 0xFF && data[1] == 0xFE) || (data[0] == 0xFE && data[1] == 0xFF)) {
            // UTF-16 with BOM
            guard let utf16 = String(data: data, encoding: .utf16) else {
                throw LinkedScriptError.unreadable("Could not decode as UTF-16")
            }
            source = utf16
        } else {
            // ISO-Latin1 fallback
            guard let latin1 = String(data: data, encoding: .isoLatin1) else {
                throw LinkedScriptError.unreadable("Could not decode as ISO-Latin1")
            }
            source = latin1
        }

        // Parse
        let isPlainText = url.pathExtension.lowercased() == "txt"
        let pages = MarkdownScriptParser.parse(source, isPlainText: isPlainText)

        // Check for empty
        if pages.isEmpty {
            throw LinkedScriptError.empty
        }

        return pages
    }
}
