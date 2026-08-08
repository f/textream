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

struct HighlightingTextEditor: NSViewRepresentable {
    @Binding var text: String
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

        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
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

        // Set initial text and apply highlighting
        textView.string = text
        context.coordinator.applyHighlighting(textView)

        updateWritingDirection(textView, text: text)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
            context.coordinator.applyHighlighting(textView)
        }
        updateWritingDirection(textView, text: text)

        // Apply bump highlight on newly dictated range
        if let range = highlightRange, range.location + range.length <= textView.string.count {
            context.coordinator.applyBumpHighlight(textView, range: range)
        }

        // Move caret to requested position (one-shot)
        if let pos = caretPosition, pos <= textView.string.count {
            let caretRange = NSRange(location: pos, length: 0)
            textView.setSelectedRange(caretRange)
            textView.scrollRangeToVisible(caretRange)
            DispatchQueue.main.async {
                self.caretPosition = nil
            }
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

        private static let annotationPattern = try! NSRegularExpression(
            pattern: "\\[[^\\]]+\\]",
            options: []
        )

        init(_ parent: HighlightingTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.updateWritingDirection(textView, text: textView.string)
            applyHighlighting(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let pos = textView.selectedRange().location
            if parent.editorCaretPosition != pos {
                DispatchQueue.main.async { [weak self] in
                    self?.parent.editorCaretPosition = pos
                }
            }
        }

        private var bumpTimer: Timer?

        func applyBumpHighlight(_ textView: NSTextView, range: NSRange) {
            guard let textStorage = textView.textStorage else { return }
            guard range.length > 0, range.location + range.length <= textStorage.length else { return }

            let bumpColor = NSColor.controlAccentColor.withAlphaComponent(0.15)
            textStorage.beginEditing()
            textStorage.addAttribute(.backgroundColor, value: bumpColor, range: range)
            textStorage.endEditing()

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

            // Preserve selection
            let selectedRanges = textView.selectedRanges

            textStorage.beginEditing()

            // Reset to default style
            let defaultAttributes: [NSAttributedString.Key: Any] = [
                .font: parent.font,
                .foregroundColor: NSColor.labelColor
            ]
            textStorage.setAttributes(defaultAttributes, range: fullRange)

            // Highlight [bracket] annotations
            let matches = Self.annotationPattern.matches(in: text, options: [], range: fullRange)
            for match in matches {
                let annotationAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFontManager.shared.convert(parent.font, toHaveTrait: .italicFontMask),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .backgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.08)
                ]
                textStorage.addAttributes(annotationAttributes, range: match.range)
            }

            textStorage.endEditing()

            // Restore selection
            textView.selectedRanges = selectedRanges
        }
    }
}
