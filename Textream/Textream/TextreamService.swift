//
//  TextreamService.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

class TextreamService: NSObject, ObservableObject {
    static let shared = TextreamService()
    private static let lastDocumentURLDefaultsKey = "lastDocumentURL"
    let overlayController = NotchOverlayController()
    let externalDisplayController = ExternalDisplayController()
    let browserServer = BrowserServer()
    let directorServer = DirectorServer()
    var onOverlayDismissed: (() -> Void)?
    var launchedExternally = false
    @Published var directorIsReading = false

    @Published private var document = EditorDocument()
    @Published private(set) var documentID = UUID()
    private(set) var formattedPages: [FormattedPage] {
        get { document.pages }
        set { document.pages = newValue }
    }
    var pages: [String] { formattedPages.map(\.text) }

    func updatePage(_ page: FormattedPage, at index: Int) {
        guard formattedPages.indices.contains(index), formattedPages[index] != page else { return }
        formattedPages[index] = page
    }

    func updatePageText(_ text: String, at index: Int, insertionColor: String? = nil) {
        guard formattedPages.indices.contains(index) else { return }
        updatePage(formattedPages[index].updatingText(text, insertionColor: insertionColor), at: index)
    }

    func appendPage() { formattedPages.append(FormattedPage()) }
    func removePage(at index: Int) {
        formattedPages.remove(at: index)
        documentID = UUID()
    }
    func importPages(_ text: [String]) {
        documentID = UUID()
        formattedPages = text.isEmpty ? [FormattedPage()] : text.map { FormattedPage($0) }
        currentFileURL = nil
    }
    @Published var currentPageIndex: Int = 0
    @Published var readPages: Set<Int> = []

    var hasNextPage: Bool {
        for i in (currentPageIndex + 1)..<pages.count {
            if !pages[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        return false
    }

    var currentPageText: String {
        guard currentPageIndex < pages.count else { return "" }
        return pages[currentPageIndex]
    }

    func readText(_ text: String, page: FormattedPage? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        launchedExternally = true
        hideMainWindow()

        overlayController.show(text: trimmed, wordColors: (page ?? FormattedPage(trimmed)).wordColors(for: splitTextIntoWords(trimmed)), hasNextPage: hasNextPage) { [weak self] in
            self?.externalDisplayController.dismiss()
            self?.browserServer.hideContent()
            self?.onOverlayDismissed?()
        }
        updatePageInfo()

        // Also show on external display if configured (same parsing as overlay)
        let words = splitTextIntoWords(trimmed)
        let totalCharCount = words.joined(separator: " ").count
        let paragraphBreaks = paragraphBreakWordIndices(in: trimmed)
        externalDisplayController.show(
            speechRecognizer: overlayController.speechRecognizer,
            words: words,
            totalCharCount: totalCharCount,
            wordColors: (page ?? FormattedPage(trimmed)).wordColors(for: words),
            paragraphBreakBeforeWordIndices: paragraphBreaks,
            hasNextPage: hasNextPage
        )

        if browserServer.isRunning {
            browserServer.showContent(
                speechRecognizer: overlayController.speechRecognizer,
                words: words,
                wordColors: (page ?? FormattedPage(trimmed)).wordColors(for: words),
                totalCharCount: totalCharCount,
                hasNextPage: hasNextPage
            )
        }
    }

    func readCurrentPage() {
        let trimmed = currentPageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        readPages.insert(currentPageIndex)
        readText(trimmed, page: formattedPages[currentPageIndex])
    }

    func advanceToNextPage() {
        // Skip empty pages
        var nextIndex = currentPageIndex + 1
        while nextIndex < pages.count {
            let text = pages[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { break }
            nextIndex += 1
        }
        guard nextIndex < pages.count else { return }
        jumpToPage(index: nextIndex)
    }

    func jumpToPage(index: Int) {
        guard index >= 0 && index < pages.count else { return }
        let text = pages[index].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Mute mic before switching page content
        let wasListening = overlayController.speechRecognizer.isListening
        if wasListening {
            overlayController.speechRecognizer.stop()
        }

        currentPageIndex = index
        readPages.insert(currentPageIndex)

        let trimmed = currentPageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Update content in-place without recreating the panel
        overlayController.updateContent(text: trimmed, wordColors: formattedPages[index].wordColors(for: splitTextIntoWords(trimmed)), hasNextPage: hasNextPage)
        updatePageInfo()

        // Also update external display content in-place
        let words = splitTextIntoWords(trimmed)
        externalDisplayController.overlayContent.words = words
        externalDisplayController.overlayContent.wordColors = formattedPages[index].wordColors(for: words)
        externalDisplayController.overlayContent.paragraphBreakBeforeWordIndices = paragraphBreakWordIndices(in: trimmed)
        externalDisplayController.overlayContent.totalCharCount = words.joined(separator: " ").count
        externalDisplayController.overlayContent.hasNextPage = hasNextPage

        if browserServer.isRunning {
            browserServer.updateContent(
                words: words,
                wordColors: formattedPages[index].wordColors(for: words),
                totalCharCount: words.joined(separator: " ").count,
                hasNextPage: hasNextPage
            )
        }

        // Unmute after new page content is loaded
        if wasListening {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let recognizer = self?.overlayController.speechRecognizer,
                      !recognizer.isListening,
                      !recognizer.isStarting else { return }
                recognizer.resume()
            }
        }
    }

    func updatePageInfo() {
        let pagePreviews = pages.enumerated().map { (i, text) in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "" }
            let preview = String(trimmed.prefix(40))
            return preview + (trimmed.count > 40 ? "…" : "")
        }
        for content in [overlayController.overlayContent, externalDisplayController.overlayContent] {
            content.pageCount = pages.count
            content.currentPageIndex = currentPageIndex
            content.pagePreviews = pagePreviews
        }
    }

    func startAllPages() {
        readPages.removeAll()
        currentPageIndex = 0
        readCurrentPage()
    }

    func hideMainWindow() {
        DispatchQueue.main.async {
            for window in NSApp.windows where !(window is NSPanel) {
                window.makeFirstResponder(nil)
                window.orderOut(nil)
            }
        }
    }

    @Published var currentFileURL: URL?

    // MARK: - File Operations

    private var lastDocumentDirectoryURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: Self.lastDocumentURLDefaultsKey),
              !path.isEmpty else { return nil }

        let directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directoryURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else { return nil }
        return directoryURL
    }

    func rememberDocumentURL(_ url: URL) {
        guard url.isFileURL else { return }
        UserDefaults.standard.set(
            url.standardizedFileURL.path,
            forKey: Self.lastDocumentURLDefaultsKey
        )
    }

    func saveFile() {
        if let url = currentFileURL {
            saveToURL(url)
        } else {
            saveFileAs()
        }
    }

    func saveFileAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "textream")!]
        panel.nameFieldStringValue = "Untitled.textream"
        panel.canCreateDirectories = true
        panel.directoryURL = currentFileURL?.deletingLastPathComponent()
            ?? lastDocumentDirectoryURL

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.saveToURL(url)
        }
    }

    @discardableResult
    func saveToURL(_ url: URL) -> Bool {
        do {
            try document.save(to: url)
            currentFileURL = url
            rememberDocumentURL(url)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to save file"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return false
        }
    }

    var hasUnsavedChanges: Bool {
        document.hasUnsavedChanges
    }

    func openFile() {
        guard confirmDiscardIfNeeded() else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .init(filenameExtension: "textream")!,
            .init(filenameExtension: "key")!,
            .init(filenameExtension: "pptx")!,
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = currentFileURL?.deletingLastPathComponent()
            ?? lastDocumentDirectoryURL

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let ext = url.pathExtension.lowercased()
            if ext == "key" {
                let alert = NSAlert()
                alert.messageText = "Keynote files can't be imported directly"
                alert.informativeText = "Please export your Keynote presentation as PowerPoint (.pptx) first:\n\nIn Keynote: File → Export To → PowerPoint"
                alert.alertStyle = .informational
                alert.runModal()
            } else if ext == "pptx" {
                self?.importPresentation(from: url)
            } else {
                self?.openFileAtURL(url)
            }
        }
    }

    func importPresentation(from url: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let notes = try PresentationNotesExtractor.extractNotes(from: url)
                DispatchQueue.main.async {
                    self?.importPages(notes)
                    self?.currentPageIndex = 0
                    self?.readPages.removeAll()
                    self?.currentFileURL = nil
                    self?.rememberDocumentURL(url)
                }
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Import Error"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    /// Returns true if it's safe to proceed (saved, discarded, or no changes).
    /// Returns false if the user cancelled.
    func confirmDiscardIfNeeded() -> Bool {
        guard hasUnsavedChanges else { return true }

        let alert = NSAlert()
        alert.messageText = "You have unsaved changes"
        alert.informativeText = "Do you want to save your changes before opening another file?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            if let url = currentFileURL { return saveToURL(url) }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.init(filenameExtension: "textream")!]
            panel.nameFieldStringValue = "Untitled.textream"
            panel.canCreateDirectories = true
            panel.directoryURL = lastDocumentDirectoryURL
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            return saveToURL(url)
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func openFileAtURL(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let loadedPages = try FormattedDocument.load(data)
            guard !loadedPages.isEmpty else { return }
            document = EditorDocument(pages: loadedPages)
            documentID = UUID()
            currentPageIndex = 0
            readPages.removeAll()
            currentFileURL = url
            rememberDocumentURL(url)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to open file"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: - Browser Server

    func updateBrowserServer() {
        if NotchSettings.shared.browserServerEnabled {
            if !browserServer.isRunning {
                browserServer.start()
            }
        } else {
            browserServer.stop()
        }
    }

    // MARK: - Director Server

    func updateDirectorServer() {
        if NotchSettings.shared.directorModeEnabled {
            if !directorServer.isRunning {
                directorServer.start()
                wireDirectorCallbacks()
            }
        } else {
            directorServer.stop()
            if directorIsReading {
                overlayController.dismiss()
                directorIsReading = false
            }
        }
    }

    private func wireDirectorCallbacks() {
        directorServer.onSetText = { [weak self] text in
            self?.setTextFromDirector(text)
        }
        directorServer.onUpdateText = { [weak self] text, readCharCount, hasFormatting in
            self?.updateTextFromDirector(text, readCharCount: readCharCount, hasFormatting: hasFormatting)
        }
        directorServer.onStop = { [weak self] in
            self?.stopDirectorReading()
        }
    }

    func setTextFromDirector(_ page: FormattedPage) {
        let trimmed = page.text
        guard !trimmed.isEmpty else { return }

        // Director mode is single page
        formattedPages = [page]
        currentPageIndex = 0
        readPages.removeAll()

        // Force word tracking mode for director
        let savedMode = NotchSettings.shared.listeningMode
        NotchSettings.shared.listeningMode = .wordTracking

        directorIsReading = true

        overlayController.show(text: trimmed, wordColors: page.wordColors(for: splitTextIntoWords(trimmed)), hasNextPage: false) { [weak self] in
            self?.directorIsReading = false
            self?.directorServer.hideContent()
            self?.externalDisplayController.dismiss()
            self?.browserServer.hideContent()
            // Restore listening mode
            NotchSettings.shared.listeningMode = savedMode
        }

        // Feed director server with speech recognizer
        let words = splitTextIntoWords(trimmed)
        let totalCharCount = words.joined(separator: " ").count
        directorServer.showContent(
            speechRecognizer: overlayController.speechRecognizer,
            words: words,
            totalCharCount: totalCharCount,
            page: page
        )

        // Also show on external display & browser if configured
        let paragraphBreaks = paragraphBreakWordIndices(in: trimmed)
        externalDisplayController.show(
            speechRecognizer: overlayController.speechRecognizer,
            words: words,
            totalCharCount: totalCharCount,
            wordColors: page.wordColors(for: words),
            paragraphBreakBeforeWordIndices: paragraphBreaks,
            hasNextPage: false
        )
        if browserServer.isRunning {
            browserServer.showContent(
                speechRecognizer: overlayController.speechRecognizer,
                words: words,
                wordColors: page.wordColors(for: words),
                totalCharCount: totalCharCount,
                hasNextPage: false
            )
        }
    }

    func updateTextFromDirector(_ incomingPage: FormattedPage, readCharCount: Int, hasFormatting: Bool) {
        guard directorIsReading else { return }
        let trimmed = incomingPage.text
        guard !trimmed.isEmpty else { return }

        let oldPage = formattedPages[0]
        let protectedOffset = oldPage.sourceUTF16Offset(
            forSpeechOffset: min(overlayController.speechRecognizer.recognizedCharCount, max(0, readCharCount)),
            words: splitTextIntoWords(oldPage.text)
        )
        let oldPrefix = oldPage.prefix(utf16Count: protectedOffset)
        guard incomingPage.text.utf16.count >= protectedOffset,
              oldPrefix.text == incomingPage.prefix(utf16Count: protectedOffset).text else { return }
        let page: FormattedPage
        if hasFormatting {
            guard oldPrefix == incomingPage.prefix(utf16Count: protectedOffset) else { return }
            page = incomingPage
        } else {
            // Legacy clients have no color metadata; keep the locked prefix intact.
            let unreadRange = NSRange(location: protectedOffset, length: incomingPage.text.utf16.count - protectedOffset)
            let unread = FormattedPage(attributedString: incomingPage.attributedString.attributedSubstring(from: unreadRange))
            page = FormattedPage(runs: oldPrefix.runs + unread.runs)
        }
        formattedPages = [page]

        let words = splitTextIntoWords(trimmed)
        let totalCharCount = words.joined(separator: " ").count

        // Preserve only the prefix that was both recognized by the Mac and
        // locked in the director's edit snapshot. Recognition can advance
        // while an update is in flight, so trusting either count alone could
        // make newly read text unexpectedly editable or overwriteable.
        let recognizedCharCount = overlayController.speechRecognizer.recognizedCharCount
        let preservedCharCount = min(
            totalCharCount,
            min(recognizedCharCount, max(0, readCharCount))
        )

        // Update overlay content without resetting speech progress
        overlayController.overlayContent.words = words
        overlayController.overlayContent.wordColors = page.wordColors(for: words)
        overlayController.overlayContent.paragraphBreakBeforeWordIndices = paragraphBreakWordIndices(in: trimmed)
        overlayController.overlayContent.totalCharCount = totalCharCount
        overlayController.overlayContent.hasNextPage = false

        // Update the speech recognizer with new full text but keep char count
        overlayController.speechRecognizer.updateText(trimmed, preservingCharCount: preservedCharCount)

        // Update director server
        directorServer.updateContent(words: words, totalCharCount: totalCharCount, page: page)

        // Update external display & browser
        externalDisplayController.overlayContent.words = words
        externalDisplayController.overlayContent.wordColors = page.wordColors(for: words)
        externalDisplayController.overlayContent.paragraphBreakBeforeWordIndices = paragraphBreakWordIndices(in: trimmed)
        externalDisplayController.overlayContent.totalCharCount = totalCharCount
        if browserServer.isRunning {
            browserServer.updateContent(
                words: words,
                wordColors: page.wordColors(for: words),
                totalCharCount: totalCharCount,
                hasNextPage: false
            )
        }
    }

    func stopDirectorReading() {
        guard directorIsReading else { return }
        overlayController.dismiss()
        directorIsReading = false
    }

    func updateKeepAwakeActivity(enabled: Bool) {
        overlayController.updateKeepAwakeActivity(enabled: enabled)
    }

    // macOS Services handler
    @objc func readInTextream(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pboard.string(forType: .string) else {
            error.pointee = "No text found on pasteboard" as NSString
            return
        }
        readText(text)
    }

    // URL scheme handler: textream://read?text=Hello%20World
    func handleURL(_ url: URL) {
        guard url.scheme == "textream" else { return }

        if url.host == "read" || url.path == "/read" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let textParam = components.queryItems?.first(where: { $0.name == "text" })?.value {
                readText(textParam)
            }
        }
    }
}
