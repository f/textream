import SwiftUI
import UIKit

/// Native rich-text editing; only text and foreground colors are persisted.
struct BracketHighlightingTextEditor: UIViewRepresentable {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Binding var page: FormattedPage
    @Binding var isFocused: Bool
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    var formatting: ScriptFormattingController? = nil
    var palette: [ScriptPaletteEntry] = []

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        // Opt in to TextKit 1 at creation time. The editor updates attributes
        // in place, and this avoids a runtime compatibility-mode transition.
        let textView = UITextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsEditingTextAttributes = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.showsVerticalScrollIndicator = true
        textView.showsHorizontalScrollIndicator = false
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = .zero
        textView.accessibilityLabel = accessibilityLabel
        textView.accessibilityIdentifier = accessibilityIdentifier
        context.coordinator.update(textView, force: true)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        textView.accessibilityLabel = accessibilityLabel
        textView.accessibilityIdentifier = accessibilityIdentifier
        context.coordinator.update(textView, force: false)
    }

    static func dismantleUIView(_ textView: UITextView, coordinator: Coordinator) {
        textView.resignFirstResponder()
        textView.delegate = nil
        textView.undoManager?.removeAllActions(withTarget: coordinator)
        if coordinator.parent.formatting?.coordinator === coordinator {
            coordinator.parent.formatting?.coordinator = nil
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: BracketHighlightingTextEditor

        private var isApplyingHighlighting = false
        private var lastStyleSignature = ""
        private var displayedPage: FormattedPage
        weak var textView: UITextView?
        private var selectionReportPending = false
        private var keyboardAccessory: UIHostingController<ScriptKeyboardAccessory>?
        private var accessoryPaletteSignature = ""

        init(parent: BracketHighlightingTextEditor) {
            self.parent = parent
            displayedPage = parent.page
        }

        func update(_ textView: UITextView, force: Bool) {
            self.textView = textView
            parent.formatting?.coordinator = self
            updateKeyboardAccessory(textView)
            let font = UIFont.preferredFont(
                forTextStyle: .body,
                compatibleWith: textView.traitCollection
            )
            let styleSignature = [
                font.fontName,
                String(describing: font.pointSize),
                textView.traitCollection.preferredContentSizeCategory.rawValue,
                String(describing: parent.dynamicTypeSize),
                String(textView.traitCollection.userInterfaceStyle.rawValue)
            ].joined(separator: "|")

            // Never replace or restyle the storage while an input method owns
            // marked text. Doing so can discard an unfinished composition.
            if textView.markedTextRange == nil {
                if force || displayedPage != parent.page {
                    replaceText(
                        in: textView,
                        with: parent.page,
                        font: font
                    )
                } else if lastStyleSignature != styleSignature {
                    applyHighlighting(to: textView, font: font)
                }
                lastStyleSignature = styleSignature
                reportSelection()
            }

            updateFocus(of: textView)
        }

        private func updateKeyboardAccessory(_ textView: UITextView) {
            guard let formatting = parent.formatting, parent.palette.count > 1 else {
                if textView.inputAccessoryView != nil {
                    textView.inputAccessoryView = nil
                    keyboardAccessory = nil
                    accessoryPaletteSignature = ""
                }
                return
            }
            let signature = parent.palette.map { "\($0.id):\($0.hex)" }.joined(separator: "|")
            guard keyboardAccessory == nil || accessoryPaletteSignature != signature else { return }
            let content = ScriptKeyboardAccessory(entries: parent.palette, formatting: formatting) { [weak textView] in
                textView?.resignFirstResponder()
            }
            if let keyboardAccessory {
                keyboardAccessory.rootView = content
            } else {
                // SwiftUI keyboard toolbar placement doesn't attach reliably to a
                // bridged UITextView; UIKit owns its input accessory directly.
                let hosting = UIHostingController(rootView: content)
                let accessory = UIInputView(frame: CGRect(x: 0, y: 0, width: 0, height: 48), inputViewStyle: .keyboard)
                hosting.view.backgroundColor = .clear
                hosting.view.frame = accessory.bounds
                hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                accessory.addSubview(hosting.view)
                textView.inputAccessoryView = accessory
                keyboardAccessory = hosting
            }
            keyboardAccessory?.overrideUserInterfaceStyle = textView.traitCollection.userInterfaceStyle
            accessoryPaletteSignature = signature
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingHighlighting else { return }
            let page = FormattedPage(attributedString: textView.attributedText)
            displayedPage = page
            if parent.page != page {
                parent.page = page
            }

            // Attribute mutations during a marked-text composition can break
            // multilingual keyboards. The final delegate callback after the
            // composition is committed applies the cue treatment instead.
            guard textView.markedTextRange == nil else { return }
            applyHighlighting(
                to: textView,
                font: UIFont.preferredFont(
                    forTextStyle: .body,
                    compatibleWith: textView.traitCollection
                )
            )
            reportSelection()
        }

        func textViewDidChangeSelection(_ textView: UITextView) { reportSelection() }

        func reportSelection() {
            guard !selectionReportPending, parent.formatting != nil else { return }
            selectionReportPending = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                selectionReportPending = false
                guard let textView, textView.markedTextRange == nil,
                      let formatting = parent.formatting, formatting.coordinator === self else { return }
                let range = textView.selectedRange
                let color: String?
                if range.length == 0 {
                    color = (textView.typingAttributes[.foregroundColor] as? UIColor)?.rgbHex ?? "#ffffff"
                } else {
                    var colors = Set<String>()
                    textView.textStorage.enumerateAttribute(.foregroundColor, in: range) { value, _, _ in
                        colors.insert((value as? UIColor)?.rgbHex ?? "#ffffff")
                    }
                    color = colors.count == 1 ? colors.first : nil
                }
                if formatting.selectedColor != color { formatting.selectedColor = color }
            }
        }

        func applyColor(_ hex: String) {
            guard let textView, textView.markedTextRange == nil else { return }
            let range = textView.selectedRange
            let color = UIColor(rgbHex: hex).editorTextColor
            if range.length > 0 {
                let before = FormattedPage(attributedString: textView.attributedText)
                textView.undoManager?.registerUndo(withTarget: self) { target in target.restorePage(before, selection: range) }
                textView.textStorage.addAttribute(.foregroundColor, value: color, range: range)
                textViewDidChange(textView)
            }
            textView.typingAttributes[.foregroundColor] = color
            reportSelection()
        }

        private func restorePage(_ page: FormattedPage, selection: NSRange) {
            guard let textView else { return }
            let current = FormattedPage(attributedString: textView.attributedText)
            textView.undoManager?.registerUndo(withTarget: self) { target in target.restorePage(current, selection: selection) }
            textView.textStorage.setAttributedString(page.editorAttributedString)
            textView.selectedRange = selection
            textViewDidChange(textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused {
                parent.isFocused = true
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused {
                parent.isFocused = false
            }
            guard textView.markedTextRange == nil else { return }
            applyHighlighting(
                to: textView,
                font: UIFont.preferredFont(
                    forTextStyle: .body,
                    compatibleWith: textView.traitCollection
                )
            )
        }

        private func updateFocus(of textView: UITextView) {
            if parent.isFocused {
                guard !textView.isFirstResponder else { return }
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self, let textView,
                          self.parent.isFocused,
                          !textView.isFirstResponder,
                          textView.window != nil else { return }
                    textView.becomeFirstResponder()
                }
            } else if textView.isFirstResponder {
                textView.resignFirstResponder()
            }
        }

        private func replaceText(
            in textView: UITextView,
            with page: FormattedPage,
            font: UIFont
        ) {
            let previousSelection = textView.selectedRange
            let previousOffset = textView.contentOffset

            isApplyingHighlighting = true
            textView.attributedText = page.editorAttributedString
            displayedPage = page
            isApplyingHighlighting = false
            applyHighlighting(to: textView, font: font)

            let utf16Length = textView.textStorage.length
            textView.selectedRange = NSRange(
                location: min(previousSelection.location, utf16Length),
                length: min(
                    previousSelection.length,
                    max(0, utf16Length - min(previousSelection.location, utf16Length))
                )
            )
            textView.setContentOffset(previousOffset, animated: false)
        }

        private func applyHighlighting(to textView: UITextView, font: UIFont) {
            guard textView.markedTextRange == nil else { return }
            let textStorage = textView.textStorage
            let selectedRange = textView.selectedRange
            let contentOffset = textView.contentOffset

            var typingAttributes = textView.typingAttributes
            typingAttributes[.font] = font
            typingAttributes[.foregroundColor] = ((typingAttributes[.foregroundColor] as? UIColor) ?? UIColor.white).editorTextColor

            isApplyingHighlighting = true
            BracketCueTextStyling.apply(to: textStorage, font: font)
            textView.typingAttributes = typingAttributes
            textView.selectedRange = selectedRange
            textView.setContentOffset(contentOffset, animated: false)
            isApplyingHighlighting = false
        }
    }
}

enum BracketCueTextStyling {
    private static let pattern = try! NSRegularExpression(
        pattern: "\\[[^\\]]+\\]",
        options: []
    )

    static func ranges(in text: String) -> [NSRange] {
        // NSRegularExpression ranges are UTF-16 based. NSString length keeps
        // cues aligned even when emoji or composed characters precede them.
        pattern.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: (text as NSString).length)
        ).map(\.range)
    }

    static func apply(to text: NSMutableAttributedString, font: UIFont) {
        let defaultAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.defaultWhiteText
        ]
        let italicFont = font.fontDescriptor.withSymbolicTraits(.traitItalic)
            .map { UIFont(descriptor: $0, size: font.pointSize) }
            ?? font
        let cueAttributes: [NSAttributedString.Key: Any] = [
            .font: italicFont,
            .backgroundColor: UIColor.secondaryLabel.withAlphaComponent(0.08)
        ]

        text.beginEditing()
        let normalized = FormattedPage(attributedString: text).editorAttributedString
        normalized.enumerateAttributes(in: NSRange(location: 0, length: normalized.length)) { attributes, range, _ in
            text.setAttributes(defaultAttributes.merging(attributes) { _, color in color }, range: range)
        }
        for range in ranges(in: text.string) {
            text.addAttributes(cueAttributes, range: range)
        }
        text.endEditing()
    }
}
