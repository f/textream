import XCTest
@testable import MarkdownScript

final class LinkedScriptStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("LinkedScriptStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testLoadPagesParsesMarkdown() throws {
        let url = try write("a.md", Data("# One\nHello\n\n---\n\nTwo".utf8))
        XCTAssertEqual(try LinkedScriptStore.loadPages(from: url), ["One\nHello", "Two"])
    }
    func testLoadPagesTxtIsPlain() throws {
        let url = try write("a.txt", Data("# keep **this**\n---\nTwo".utf8))
        XCTAssertEqual(try LinkedScriptStore.loadPages(from: url), ["# keep **this**", "Two"])
    }
    func testLoadPagesExtensionCaseInsensitive() throws {
        let url = try write("a.TXT", Data("# keep".utf8))
        XCTAssertEqual(try LinkedScriptStore.loadPages(from: url), ["# keep"])
    }
    func testLoadPagesEmptyFileThrowsEmpty() throws {
        let url = try write("e.md", Data())
        XCTAssertThrowsError(try LinkedScriptStore.loadPages(from: url)) {
            guard case LinkedScriptError.empty = $0 else { return XCTFail("expected .empty, got \($0)") }
        }
    }
    func testLoadPagesMarkupOnlyThrowsEmpty() throws {
        let url = try write("m.md", Data("---\n```\ncode\n```".utf8))
        XCTAssertThrowsError(try LinkedScriptStore.loadPages(from: url)) {
            guard case LinkedScriptError.empty = $0 else { return XCTFail("expected .empty, got \($0)") }
        }
    }
    func testLoadPagesMissingFileThrowsUnreadable() {
        let url = dir.appendingPathComponent("nope.md")
        XCTAssertThrowsError(try LinkedScriptStore.loadPages(from: url)) {
            guard case LinkedScriptError.unreadable = $0 else { return XCTFail("expected .unreadable, got \($0)") }
        }
    }
    func testLoadPagesUTF16WithBOM() throws {
        var data = Data([0xFF, 0xFE])
        data.append("Hello".data(using: .utf16LittleEndian)!)
        let url = try write("u16.md", data)
        XCTAssertEqual(try LinkedScriptStore.loadPages(from: url), ["Hello"])
    }
    func testLoadPagesLatin1Fallback() throws {
        let url = try write("l1.md", Data([0x43, 0x61, 0x66, 0xE9])) // "Café" in Latin-1, invalid UTF-8
        XCTAssertEqual(try LinkedScriptStore.loadPages(from: url), ["Café"])
    }
    func testBookmarkRoundTrip() throws {
        let url = try write("b.md", Data("Hello".utf8))
        let data = try LinkedScriptStore.makeBookmark(for: url)
        let resolved = try LinkedScriptStore.resolveBookmark(data)
        XCTAssertEqual(resolved.url.standardizedFileURL.resolvingSymlinksInPath().path,
                       url.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertFalse(resolved.isStale)
    }
    func testResolveGarbageBookmarkThrows() {
        XCTAssertThrowsError(try LinkedScriptStore.resolveBookmark(Data([1, 2, 3]))) {
            guard case LinkedScriptError.bookmarkInvalid = $0 else { return XCTFail("expected .bookmarkInvalid, got \($0)") }
        }
    }
}
