//
//  HighlightingTextEditor.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 26.02.2026.
//

import SwiftUI
import AppKit

extension NSFont {
    var rounded: NSFont {
        guard let descriptor = fontDescriptor.withDesign(.rounded) else { return self }
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

@Observable
class EditorFormattingController {
    var selectedColor: String?
    @ObservationIgnored weak var coordinator: HighlightingTextEditor.Coordinator?

    func applyColor(_ hex: String) { coordinator?.applyColor(hex) }
}

final class FormattingTextView: NSTextView {
    override func becomeFirstResponder() -> Bool {
        // NSTextView synchronizes the shared color panel when focus returns.
        // Release the palette target before that can overwrite its saved color.
        PaletteRow.closeActivePicker()
        return super.becomeFirstResponder()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshDefaultTextColor()
    }

    func refreshDefaultTextColor() {
        guard let textStorage, let layoutManager else { return }
        let range = NSRange(location: 0, length: textStorage.length)
        // Rendering-only attributes keep imported black intact for saving and light mode.
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        textStorage.enumerateAttribute(.foregroundColor, in: range) { value, range, _ in
            let color = (value as? NSColor)?.rgbHex ?? "#ffffff"
            if color == "#000000" || color == "#ffffff" {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: isDark ? NSColor.white : NSColor.black, forCharacterRange: range)
            }
        }
    }
}

struct HighlightingTextEditor: NSViewRepresentable {
    @Binding var page: FormattedPage
    let formatting: EditorFormattingController
    var font: NSFont = .systemFont(ofSize: 16, weight: .regular)
    var isFocused: FocusState<Bool>.Binding?
    /// Range of newly dictated text to highlight with a bump effect
    var highlightRange: NSRange? = nil
    /// One-shot: set caret to this position, then nilled out
    @Binding var caretPosition: Int?
    /// Continuously reported current caret position in the editor
    @Binding var editorCaretPosition: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = FormattingTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = true
        textView.usesAdaptiveColorMappingForDarkAppearance = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = font
        textView.delegate = context.coordinator
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        context.coordinator.textView = textView
        formatting.coordinator = context.coordinator
        textView.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]

        // Set initial text and apply highlighting
        textView.textStorage?.setAttributedString(page.attributedString)
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor.white]
        context.coordinator.applyHighlighting(textView)
        context.coordinator.reportSelection()

        updateWritingDirection(textView, text: page.text)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        formatting.coordinator = context.coordinator

        if context.coordinator.displayedPage != page {
            let selectedRanges = textView.selectedRanges
            textView.textStorage?.setAttributedString(page.attributedString)
            textView.selectedRanges = selectedRanges.map { value in
                let range = value.rangeValue
                let location = min(range.location, textView.string.utf16.count)
                return NSValue(range: NSRange(location: location, length: min(range.length, textView.string.utf16.count - location)))
            }
            context.coordinator.applyHighlighting(textView)
            context.coordinator.displayedPage = page
            context.coordinator.reportSelection()
        }
        updateWritingDirection(textView, text: page.text)

        // Apply bump highlight on newly dictated range
        if let range = highlightRange, range != context.coordinator.lastBumpRange,
           NSMaxRange(range) <= textView.string.utf16.count {
            context.coordinator.applyBumpHighlight(textView, range: range)
        }
        context.coordinator.lastBumpRange = highlightRange

        // Move caret to requested position (one-shot)
        if let pos = caretPosition, pos <= textView.string.count {
            let caretRange = NSRange(location: String(textView.string.prefix(pos)).utf16.count, length: 0)
            textView.setSelectedRange(caretRange)
            textView.scrollRangeToVisible(caretRange)
            DispatchQueue.main.async {
                self.caretPosition = nil
            }
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.bumpTimer?.invalidate()
        if let textView = coordinator.textView {
            textView.undoManager?.removeAllActions(withTarget: textView)
            if let storage = textView.textStorage { textView.undoManager?.removeAllActions(withTarget: storage) }
            textView.delegate = nil
        }
        if coordinator.parent.formatting.coordinator === coordinator {
            coordinator.parent.formatting.coordinator = nil
        }
    }

    /// Set the text view's base writing direction based on the content's script.
    private func updateWritingDirection(_ textView: NSTextView, text: String) {
        switch textBaseDirection(in: text) {
        case .rightToLeft:
            textView.baseWritingDirection = .rightToLeft
        case .leftToRight:
            textView.baseWritingDirection = .leftToRight
        case .natural:
            textView.baseWritingDirection = .natural
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HighlightingTextEditor
        weak var textView: NSTextView?
        var displayedPage: FormattedPage
        var lastBumpRange: NSRange?
        private var selectionReportPending = false

        private static let annotationPattern = try! NSRegularExpression(
            pattern: "\\[[^\\]]+\\]",
            options: []
        )

        init(_ parent: HighlightingTextEditor) {
            self.parent = parent
            displayedPage = parent.page
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            applyHighlighting(textView)
            parent.updateWritingDirection(textView, text: textView.string)
            displayedPage = FormattedPage(attributedString: textView.attributedString())
            parent.page = displayedPage
            reportSelection()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            reportSelection()
        }

        func textViewDidChangeTypingAttributes(_ notification: Notification) { reportSelection() }

        func reportSelection() {
            guard !selectionReportPending else { return }
            selectionReportPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.selectionReportPending = false
                guard let textView = self.textView,
                      self.parent.formatting.coordinator === self else { return }
                let selection = textView.selectedRange()
                let pos = (textView.string as NSString).substring(to: min(selection.location, textView.string.utf16.count)).count
                if self.parent.editorCaretPosition != pos { self.parent.editorCaretPosition = pos }
                var color: String?
                if selection.length == 0 {
                    color = (textView.typingAttributes[.foregroundColor] as? NSColor)?.rgbHex ?? "#ffffff"
                } else {
                    var colors = Set<String>()
                    textView.textStorage?.enumerateAttribute(.foregroundColor, in: selection) { value, _, _ in
                        colors.insert((value as? NSColor)?.rgbHex ?? "#ffffff")
                    }
                    if colors.count == 1 { color = colors.first }
                }
                if self.parent.formatting.selectedColor != color { self.parent.formatting.selectedColor = color }
            }
        }

        func applyColor(_ hex: String) {
            guard let textView else { return }
            let color = NSColor(rgbHex: hex)
            let range = textView.selectedRange()
            if range.length > 0, textView.shouldChangeText(in: range, replacementString: nil) {
                textView.setTextColor(color, range: range)
                textView.didChangeText()
            }
            textView.typingAttributes[.foregroundColor] = color
            textView.window?.makeFirstResponder(textView)
            reportSelection()
        }

        var bumpTimer: Timer?

        func applyBumpHighlight(_ textView: NSTextView, range: NSRange) {
            guard let textStorage = textView.textStorage else { return }
            guard range.length > 0, range.location + range.length <= textStorage.length else { return }

            let bumpColor = NSColor.controlAccentColor.withAlphaComponent(0.15)
            textStorage.beginEditing()
            textStorage.addAttribute(.backgroundColor, value: bumpColor, range: range)
            textStorage.endEditing()
            (textView as? FormattingTextView)?.refreshDefaultTextColor()

            // Fade out after a short delay
            bumpTimer?.invalidate()
            bumpTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self, weak textView] _ in
                guard let self, let textView else { return }
                self.applyHighlighting(textView)
            }
        }

        func applyHighlighting(_ textView: NSTextView) {
            guard let textStorage = textView.textStorage else { return }
            let fullRange = NSRange(location: 0, length: textStorage.length)
            let text = textStorage.string

            // Styling must not change the next typing color or move the selection.
            let typingAttributes = textView.typingAttributes

            textStorage.beginEditing()

            // Keep only foreground colors; pasted fonts and transient cue styling aren't document data.
            let normalized = FormattedPage(attributedString: textStorage).attributedString
            normalized.enumerateAttributes(in: fullRange) { attributes, range, _ in
                textStorage.setAttributes(attributes.merging([.font: parent.font]) { _, new in new }, range: range)
            }

            // Highlight [bracket] annotations
            let matches = Self.annotationPattern.matches(in: text, options: [], range: fullRange)
            for match in matches {
                let annotationAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFontManager.shared.convert(parent.font, toHaveTrait: .italicFontMask),
                    .backgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.08)
                ]
                textStorage.addAttributes(annotationAttributes, range: match.range)
            }

            textStorage.endEditing()

            (textView as? FormattingTextView)?.refreshDefaultTextColor()
            textView.typingAttributes = typingAttributes.merging([.font: parent.font]) { _, new in new }
        }
    }
}
