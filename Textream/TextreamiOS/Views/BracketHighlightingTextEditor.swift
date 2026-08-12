import SwiftUI
import UIKit

/// A plain-text script editor that presents balanced bracket cues with the
/// same visual treatment as the macOS editor. Styling lives only in the text
/// view; the bound value remains an ordinary `String`.
struct BracketHighlightingTextEditor: UIViewRepresentable {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Binding var text: String
    @Binding var isFocused: Bool
    let accessibilityLabel: String
    let accessibilityIdentifier: String

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
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: BracketHighlightingTextEditor

        private var isApplyingHighlighting = false
        private var lastStyleSignature = ""

        init(parent: BracketHighlightingTextEditor) {
            self.parent = parent
        }

        func update(_ textView: UITextView, force: Bool) {
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
                if force || textView.text != parent.text {
                    replaceText(
                        in: textView,
                        with: parent.text,
                        font: font
                    )
                } else if lastStyleSignature != styleSignature {
                    applyHighlighting(to: textView, font: font)
                }
                lastStyleSignature = styleSignature
            }

            updateFocus(of: textView)
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingHighlighting else { return }
            let newText = textView.text ?? ""
            if parent.text != newText {
                parent.text = newText
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
            with text: String,
            font: UIFont
        ) {
            let previousSelection = textView.selectedRange
            let previousOffset = textView.contentOffset

            isApplyingHighlighting = true
            textView.attributedText = NSAttributedString(string: text)
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

            let defaultAttributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.label
            ]

            isApplyingHighlighting = true
            BracketCueTextStyling.apply(to: textStorage, font: font)
            textView.typingAttributes = defaultAttributes
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
            .foregroundColor: UIColor.label
        ]
        let italicFont = font.fontDescriptor.withSymbolicTraits(.traitItalic)
            .map { UIFont(descriptor: $0, size: font.pointSize) }
            ?? font
        let cueAttributes: [NSAttributedString.Key: Any] = [
            .font: italicFont,
            .foregroundColor: UIColor.secondaryLabel,
            .backgroundColor: UIColor.secondaryLabel.withAlphaComponent(0.08)
        ]

        text.beginEditing()
        text.setAttributes(
            defaultAttributes,
            range: NSRange(location: 0, length: text.length)
        )
        for range in ranges(in: text.string) {
            text.addAttributes(cueAttributes, range: range)
        }
        text.endEditing()
    }
}
