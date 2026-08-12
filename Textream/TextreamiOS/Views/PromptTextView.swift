import SwiftUI
import UIKit

struct PromptScrollAnimation: Equatable {
    let startOffset: CGFloat
    let targetOffset: CGFloat
    let startTime: CFTimeInterval
    let duration: CFTimeInterval

    func offset(at timestamp: CFTimeInterval) -> CGFloat {
        guard duration > 0 else { return targetOffset }
        let linearProgress = max(0, min(1, (timestamp - startTime) / duration))
        // Cubic ease-out keeps recognition updates responsive while removing
        // the visible line-to-line snap.
        let easedProgress = 1 - pow(1 - linearProgress, 3)
        return startOffset + (targetOffset - startOffset) * CGFloat(easedProgress)
    }

    func isComplete(at timestamp: CFTimeInterval) -> Bool {
        timestamp >= startTime + duration
    }

    func retargeted(
        to newTarget: CGFloat,
        at timestamp: CFTimeInterval,
        duration newDuration: CFTimeInterval
    ) -> PromptScrollAnimation {
        PromptScrollAnimation(
            startOffset: offset(at: timestamp),
            targetOffset: newTarget,
            startTime: timestamp,
            duration: newDuration
        )
    }

    static func shouldAnimate(requested: Bool, reduceMotion: Bool) -> Bool {
        requested && !reduceMotion
    }

    static func duration(forDistance distance: CGFloat) -> CFTimeInterval {
        min(0.45, max(0.24, CFTimeInterval(abs(distance) / 900)))
    }
}

struct PromptScrollRequest: Equatable {
    let wordProgress: Double
    let animated: Bool

    static func resolve(
        prompt: PromptScript,
        highlightedCharacterCount: Int,
        continuousWordProgress: Double?,
        force: Bool
    ) -> PromptScrollRequest {
        if let continuousWordProgress {
            return PromptScrollRequest(
                wordProgress: continuousWordProgress,
                animated: false
            )
        }
        return PromptScrollRequest(
            wordProgress: prompt.wordProgress(
                forCharacterOffset: highlightedCharacterCount
            ),
            animated: !force
        )
    }
}

struct PromptReadingAnchorLayout {
    static let overlayGap: CGFloat = 12

    static func effectiveAnchorY(
        viewportHeight: CGFloat,
        lineHeight: CGFloat,
        position: PromptReadingPosition,
        topOverlayClearance: CGFloat,
        bottomOverlayClearance: CGFloat
    ) -> CGFloat {
        let safeViewportHeight = max(0, viewportHeight)
        let halfLineHeight = max(0, lineHeight * 0.5)
        let minimumLineCenter = min(halfLineHeight, safeViewportHeight * 0.5)
        let maximumLineCenter = max(minimumLineCenter, safeViewportHeight - minimumLineCenter)
        let lowerBound = max(
            minimumLineCenter,
            max(0, topOverlayClearance) + overlayGap + halfLineHeight
        )
        let upperBound = min(
            maximumLineCenter,
            safeViewportHeight
                - max(0, bottomOverlayClearance)
                - overlayGap
                - halfLineHeight
        )

        guard lowerBound <= upperBound else {
            // Very short landscape windows or large accessibility controls can
            // consume the usable stage. Keep the anchor finite and centered
            // between the remaining physical edges until the layout expands.
            return min(
                maximumLineCenter,
                max(minimumLineCenter, (lowerBound + upperBound) * 0.5)
            )
        }

        let desiredAnchor: CGFloat = switch position {
        case .nearCamera: lowerBound
        case .center: safeViewportHeight * 0.5
        }
        return min(upperBound, max(lowerBound, desiredAnchor))
    }
}

struct PromptTextView: UIViewRepresentable {
    let prompt: PromptScript
    let highlightedCharacterCount: Int
    let font: UIFont
    let textColor: UIColor
    let cueColor: UIColor
    let cueUnreadOpacity: Double
    let cueReadOpacity: Double
    let wordTracking: Bool
    let continuousWordProgress: Double?
    let allowsHorizontalSpeedAdjustment: Bool
    let readingPosition: PromptReadingPosition
    let topOverlayClearance: CGFloat
    let bottomOverlayClearance: CGFloat
    let horizontalTextInsets: UIEdgeInsets
    let onWordTap: (Int) -> Void
    let onManualScrollBegan: () -> Void
    let onManualScrollEnded: (Int) -> Void
    let onSpeedAdjustmentBegan: () -> Void
    let onSpeedAdjustmentChanged: (CGFloat, CGFloat) -> Void
    let onSpeedAdjustmentEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> PromptUITextView {
        // This view intentionally uses NSLayoutManager APIs for exact glyph
        // positions. Opt in to TextKit 1 at creation time instead of making a
        // TextKit 2 text view fall back to compatibility mode at runtime.
        let textView = PromptUITextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = true
        textView.showsVerticalScrollIndicator = false
        textView.showsHorizontalScrollIndicator = false
        textView.backgroundColor = .clear
        textView.textContainer.lineFragmentPadding = 0
        textView.contentInsetAdjustmentBehavior = .never
        textView.alwaysBounceVertical = true
        textView.decelerationRate = .fast
        textView.isDirectionalLockEnabled = true
        textView.readingPosition = readingPosition
        textView.topOverlayClearance = topOverlayClearance
        textView.bottomOverlayClearance = bottomOverlayClearance
        textView.horizontalTextInsets = horizontalTextInsets
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didTap(_:)))
        tap.cancelsTouchesInView = false
        textView.addGestureRecognizer(tap)
        context.coordinator.installSpeedAdjustmentGesture(on: textView)
        context.coordinator.update(textView: textView, force: true)
        return textView
    }

    func updateUIView(_ textView: PromptUITextView, context: Context) {
        context.coordinator.parent = self
        textView.readingPosition = readingPosition
        textView.topOverlayClearance = topOverlayClearance
        textView.bottomOverlayClearance = bottomOverlayClearance
        textView.horizontalTextInsets = horizontalTextInsets
        context.coordinator.update(textView: textView, force: false)
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: PromptTextView
        private var lastText = ""
        private var lastProgress = -1
        private var lastContinuousProgress: Double?
        private var lastStyleSignature = ""
        private var lastReadingPosition: PromptReadingPosition?
        private var lastTopOverlayClearance: CGFloat = -1
        private var lastBottomOverlayClearance: CGFloat = -1
        private var lastHorizontalTextInsets: UIEdgeInsets?
        private var lastViewportSize: CGSize?
        private var isDragging = false
        private weak var speedAdjustmentGesture: UIPanGestureRecognizer?

        init(parent: PromptTextView) {
            self.parent = parent
        }

        func update(textView: PromptUITextView, force: Bool) {
            let signature = [
                parent.font.fontName,
                String(describing: parent.font.pointSize),
                parent.textColor.description,
                parent.cueColor.description,
                String(parent.cueUnreadOpacity),
                String(parent.cueReadOpacity),
                String(parent.wordTracking)
            ].joined(separator: "|")
            let progressChanged = lastProgress != parent.highlightedCharacterCount
                || lastContinuousProgress != parent.continuousWordProgress
            let viewportGeometryChanged = lastReadingPosition != parent.readingPosition
                || abs(lastTopOverlayClearance - parent.topOverlayClearance) > 0.5
                || abs(lastBottomOverlayClearance - parent.bottomOverlayClearance) > 0.5
                || Self.insetsDiffer(lastHorizontalTextInsets, parent.horizontalTextInsets)
                || Self.sizesDiffer(lastViewportSize, textView.bounds.size)
            let needsTextUpdate = force
                || lastText != parent.prompt.text
                || lastStyleSignature != signature

            if needsTextUpdate {
                let previousOffset = textView.contentOffset
                textView.attributedText = makeAttributedString()
                textView.invalidateScrollGeometry()
                if !force || isDragging { textView.contentOffset = previousOffset }
                lastText = parent.prompt.text
                lastStyleSignature = signature
            } else if parent.wordTracking, progressChanged {
                // Speech recognition can publish several partial results per
                // second. Updating the existing text storage preserves the
                // viewport and any in-flight scroll animation; assigning a new
                // attributedText here resets UITextView's scroll position.
                textView.textStorage.beginEditing()
                applyProgressColors(to: textView.textStorage)
                textView.textStorage.endEditing()
            }
            lastProgress = parent.highlightedCharacterCount
            lastContinuousProgress = parent.continuousWordProgress
            lastReadingPosition = parent.readingPosition
            lastTopOverlayClearance = parent.topOverlayClearance
            lastBottomOverlayClearance = parent.bottomOverlayClearance
            lastHorizontalTextInsets = parent.horizontalTextInsets
            lastViewportSize = textView.bounds.size

            guard !isDragging,
                  force || progressChanged || needsTextUpdate || viewportGeometryChanged else { return }
            DispatchQueue.main.async { [weak textView, weak self] in
                guard let textView, let self, !self.isDragging else { return }
                textView.layoutIfNeeded()
                let request = PromptScrollRequest.resolve(
                    prompt: self.parent.prompt,
                    highlightedCharacterCount: self.parent.highlightedCharacterCount,
                    continuousWordProgress: self.parent.continuousWordProgress,
                    force: force || viewportGeometryChanged
                )
                if self.parent.wordTracking,
                   self.parent.readingPosition == .nearCamera {
                    textView.scrollLastSpokenLine(
                        toCharacterOffset: self.parent.highlightedCharacterCount,
                        in: self.parent.prompt,
                        animated: request.animated
                    )
                } else {
                    textView.scroll(
                        toWordProgress: request.wordProgress,
                        in: self.parent.prompt,
                        // On creation, place restored progress immediately.
                        // Subsequent Follow updates glide from the current
                        // presentation position to the newest recognized word.
                        animated: request.animated
                    )
                }
            }
        }

        @objc func didTap(_ recognizer: UITapGestureRecognizer) {
            guard let textView = recognizer.view as? PromptUITextView,
                  let offset = textView.characterOffset(at: recognizer.location(in: textView), in: parent.prompt) else {
                return
            }
            parent.onWordTap(offset)
        }

        func installSpeedAdjustmentGesture(on textView: PromptUITextView) {
            guard speedAdjustmentGesture == nil else { return }
            let gesture = UIPanGestureRecognizer(
                target: self,
                action: #selector(didSwipeToAdjustSpeed(_:))
            )
            gesture.maximumNumberOfTouches = 1
            gesture.cancelsTouchesInView = false
            gesture.delegate = self
            textView.addGestureRecognizer(gesture)

            // Give the horizontal recognizer first refusal. It fails
            // immediately for vertical movement, allowing UITextView's normal
            // vertical pan to proceed without both gestures changing state.
            textView.panGestureRecognizer.require(toFail: gesture)
            speedAdjustmentGesture = gesture
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === speedAdjustmentGesture,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  parent.allowsHorizontalSpeedAdjustment else { return false }
            let velocity = pan.velocity(in: pan.view)
            let translation = pan.translation(in: pan.view)
            let accepted = PromptScrollSpeedAdjustment.isHorizontalSwipe(
                velocity: velocity,
                translation: translation
            )
            return accepted
        }

        @objc private func didSwipeToAdjustSpeed(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            switch gesture.state {
            case .began:
                parent.onSpeedAdjustmentBegan()
            case .changed:
                parent.onSpeedAdjustmentChanged(
                    gesture.translation(in: view).x,
                    view.bounds.width
                )
            case .ended, .cancelled, .failed:
                parent.onSpeedAdjustmentEnded()
            case .possible:
                break
            @unknown default:
                parent.onSpeedAdjustmentEnded()
            }
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            (scrollView as? PromptUITextView)?.cancelProgrammaticScrollAnimation()
            isDragging = true
            parent.onManualScrollBegan()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { finishDragging(scrollView) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            finishDragging(scrollView)
        }

        private func finishDragging(_ scrollView: UIScrollView) {
            guard let textView = scrollView as? PromptUITextView else { return }
            isDragging = false
            parent.onManualScrollEnded(textView.characterOffsetAtAnchor(in: parent.prompt))
        }

        private static func insetsDiffer(
            _ previous: UIEdgeInsets?,
            _ current: UIEdgeInsets
        ) -> Bool {
            guard let previous else { return true }
            return abs(previous.left - current.left) > 0.5
                || abs(previous.right - current.right) > 0.5
        }

        private static func sizesDiffer(_ previous: CGSize?, _ current: CGSize) -> Bool {
            guard let previous else { return true }
            return abs(previous.width - current.width) > 0.5
                || abs(previous.height - current.height) > 0.5
        }

        private func makeAttributedString() -> NSAttributedString {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .natural
            paragraph.baseWritingDirection = parent.prompt.direction == .rightToLeft
                ? .rightToLeft
                : .leftToRight
            paragraph.lineSpacing = max(8, parent.font.pointSize * 0.28)
            paragraph.paragraphSpacing = parent.font.pointSize * 0.22
            paragraph.hyphenationFactor = 0

            let result = NSMutableAttributedString(
                string: parent.prompt.text,
                attributes: [
                    .font: parent.font,
                    .foregroundColor: parent.textColor.withAlphaComponent(parent.wordTracking ? 1 : 0.94),
                    .paragraphStyle: paragraph,
                    .kern: parent.font.pointSize * 0.008
                ]
            )

            let italicDescriptor = parent.font.fontDescriptor.withSymbolicTraits(.traitItalic)
            let italicFont = italicDescriptor.map {
                UIFont(descriptor: $0, size: parent.font.pointSize)
            } ?? parent.font
            for range in parent.prompt.annotationStyleRanges {
                var attributes: [NSAttributedString.Key: Any] = [.font: italicFont]
                if italicDescriptor == nil {
                    // Some bundled faces do not publish a dedicated italic
                    // trait. Match SwiftUI/macOS's synthetic italic fallback
                    // without shrinking the cue text.
                    attributes[.obliqueness] = 0.12
                }
                result.addAttributes(
                    attributes,
                    range: parent.prompt.nsRange(forCharacterRange: range)
                )
            }
            applyProgressColors(to: result)
            return result
        }

        private func applyProgressColors(to result: NSMutableAttributedString) {
            let fullRange = NSRange(location: 0, length: result.length)
            result.addAttribute(
                .foregroundColor,
                value: parent.textColor.withAlphaComponent(parent.wordTracking ? 1 : 0.94),
                range: fullRange
            )
            result.removeAttribute(.underlineStyle, range: fullRange)
            result.removeAttribute(.underlineColor, range: fullRange)

            if parent.wordTracking, parent.highlightedCharacterCount > 0 {
                result.addAttribute(
                    .foregroundColor,
                    value: parent.textColor.withAlphaComponent(0.3),
                    range: parent.prompt.nsRange(upToCharacterOffset: parent.highlightedCharacterCount)
                )
                if let activeWord = parent.prompt.activeWord(atCharacterOffset: parent.highlightedCharacterCount),
                   !activeWord.isAnnotation {
                    result.addAttributes(
                        [
                            .foregroundColor: parent.textColor.withAlphaComponent(0.7),
                            .underlineStyle: NSUnderlineStyle.single.rawValue,
                            .underlineColor: parent.textColor.withAlphaComponent(0.6)
                        ],
                        range: parent.prompt.nsRange(forCharacterRange: activeWord.characterRange)
                    )
                }
            }

            for range in parent.prompt.annotationStyleRanges {
                let wasRead = range.upperBound <= parent.highlightedCharacterCount
                let opacity = parent.wordTracking && wasRead
                    ? parent.cueReadOpacity
                    : parent.cueUnreadOpacity
                let cueRange = parent.prompt.nsRange(forCharacterRange: range)
                result.addAttributes(
                    [
                        .foregroundColor: parent.cueColor.withAlphaComponent(opacity),
                        .underlineStyle: 0
                    ],
                    range: cueRange
                )
                result.removeAttribute(.underlineColor, range: cueRange)
            }
        }
    }
}

final class PromptUITextView: UITextView {
    var readingPosition: PromptReadingPosition = .nearCamera {
        didSet {
            guard oldValue != readingPosition else { return }
            invalidateScrollGeometry()
            setNeedsLayout()
        }
    }
    var topOverlayClearance: CGFloat = 0 {
        didSet {
            guard abs(oldValue - topOverlayClearance) > 0.5 else { return }
            invalidateScrollGeometry()
            setNeedsLayout()
        }
    }
    var bottomOverlayClearance: CGFloat = 0 {
        didSet {
            guard abs(oldValue - bottomOverlayClearance) > 0.5 else { return }
            invalidateScrollGeometry()
            setNeedsLayout()
        }
    }
    var horizontalTextInsets: UIEdgeInsets = .zero {
        didSet {
            guard abs(oldValue.left - horizontalTextInsets.left) > 0.5
                    || abs(oldValue.right - horizontalTextInsets.right) > 0.5 else { return }
            invalidateScrollGeometry()
            setNeedsLayout()
        }
    }
    private(set) var effectiveAnchorY: CGFloat = 0
    private var lineAnchors: [LineAnchor] = []
    private var lineAnchorTextLength = -1
    private var lineAnchorWidth: CGFloat = -1
    private var scrollAnimation: PromptScrollAnimation?
    private var scrollDisplayLink: CADisplayLink?
    private lazy var scrollDisplayLinkTarget = PromptScrollDisplayLinkTarget(textView: self)

    private struct LineAnchor {
        let wordProgress: Double
        let centerY: CGFloat
    }

    override func layoutSubviews() {
        let previousInsets = textContainerInset
        let attributedFont = attributedText.length > 0
            ? attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
            : nil
        let lineHeight = attributedFont?.lineHeight ?? font?.lineHeight ?? 24
        // Keep the viewport full-bleed under the controls. Empty text-container
        // space, rather than SwiftUI view padding, lets the first and final
        // lines reach a readable anchor without clipping the scrolling canvas.
        let halfLineHeight = lineHeight * 0.5
        effectiveAnchorY = PromptReadingAnchorLayout.effectiveAnchorY(
            viewportHeight: bounds.height,
            lineHeight: lineHeight,
            position: readingPosition,
            topOverlayClearance: topOverlayClearance,
            bottomOverlayClearance: bottomOverlayClearance
        )
        let topPadding = max(0, effectiveAnchorY - halfLineHeight)
        let bottomPadding = max(0, bounds.height - effectiveAnchorY + halfLineHeight)
        let leftPadding = max(0, horizontalTextInsets.left)
        let rightPadding = max(0, horizontalTextInsets.right)
        textContainerInset = UIEdgeInsets(
            top: topPadding,
            left: leftPadding,
            bottom: bottomPadding,
            right: rightPadding
        )
        super.layoutSubviews()
        if abs(previousInsets.top - topPadding) > 1
            || abs(previousInsets.bottom - bottomPadding) > 1
            || abs(previousInsets.left - leftPadding) > 1
            || abs(previousInsets.right - rightPadding) > 1 {
            invalidateScrollGeometry()
            layoutManager.ensureLayout(for: textContainer)
        }
        if abs(lineAnchorWidth - availableTextWidth) > 0.5 { invalidateScrollGeometry() }
    }

    func invalidateScrollGeometry() {
        lineAnchors = []
        lineAnchorTextLength = -1
        lineAnchorWidth = -1
    }

    func cancelProgrammaticScrollAnimation() {
        guard let animation = scrollAnimation else { return }
        let currentOffset = animation.offset(at: CACurrentMediaTime())
        stopScrollDisplayLink()
        setContentOffset(CGPoint(x: 0, y: currentOffset), animated: false)
    }

    /// Smoothly advances between wrapped text lines from a fractional word
    /// position. Interpolating line anchors prevents the long stationary
    /// periods caused by scrolling only when an integer character enters a new
    /// line.
    func scroll(toWordProgress progress: Double, in prompt: PromptScript, animated: Bool) {
        guard !prompt.text.isEmpty, bounds.height > 0 else { return }
        let anchors = scrollLineAnchors(in: prompt)
        guard let first = anchors.first else { return }

        let clampedProgress = max(0, min(progress, Double(prompt.words.count)))
        var targetY = first.centerY
        if clampedProgress >= first.wordProgress {
            targetY = anchors.last?.centerY ?? first.centerY
            for index in 0..<(anchors.count - 1) {
                let current = anchors[index]
                let next = anchors[index + 1]
                guard clampedProgress < next.wordProgress else { continue }
                let span = max(0.000_1, next.wordProgress - current.wordProgress)
                let fraction = CGFloat(max(0, min(1, (clampedProgress - current.wordProgress) / span)))
                targetY = current.centerY + (next.centerY - current.centerY) * fraction
                break
            }
        }
        scroll(toTextContainerY: targetY, animated: animated)
    }

    func scroll(toCharacterOffset offset: Int, in prompt: PromptScript, animated: Bool) {
        guard !prompt.text.isEmpty, bounds.height > 0 else { return }
        layoutManager.ensureLayout(for: textContainer)
        let clampedOffset = max(0, min(offset, prompt.characterCount))
        let rangeEnd = min(prompt.characterCount, clampedOffset + 1)
        let characterRange = prompt.nsRange(
            forCharacterRange: clampedOffset..<rangeEnd
        )
        let safeLocation = min(characterRange.location, max(0, textStorage.length - 1))
        let safeLength = max(
            1,
            min(characterRange.length, max(0, textStorage.length - safeLocation))
        )
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: safeLocation, length: safeLength),
            actualCharacterRange: nil
        )
        guard glyphRange.location < layoutManager.numberOfGlyphs else { return }
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        scroll(toTextContainerY: rect.midY, animated: animated)
    }

    /// Keeps the visual line containing the last spoken readable character at
    /// the Near Camera anchor. Word-progress interpolation is ideal for timer
    /// modes, but in Follow it moves the spoken line above the camera anchor
    /// while recognition is still advancing within that wrapped line.
    func scrollLastSpokenLine(
        toCharacterOffset offset: Int,
        in prompt: PromptScript,
        animated: Bool
    ) {
        guard !prompt.text.isEmpty, bounds.height > 0 else { return }
        layoutManager.ensureLayout(for: textContainer)
        let characterOffset = Self.lastSpokenReadableCharacterOffset(
            recognizedCharacterCount: offset,
            in: prompt
        )
        let characterRange = prompt.nsRange(
            forCharacterRange: characterOffset..<min(prompt.characterCount, characterOffset + 1)
        )
        guard textStorage.length > 0 else { return }
        let safeLocation = min(characterRange.location, max(0, textStorage.length - 1))
        let safeLength = max(
            1,
            min(characterRange.length, textStorage.length - safeLocation)
        )
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: safeLocation, length: safeLength),
            actualCharacterRange: nil
        )
        guard glyphRange.location < layoutManager.numberOfGlyphs else { return }
        let lineRect = layoutManager.lineFragmentUsedRect(
            forGlyphAt: glyphRange.location,
            effectiveRange: nil
        )
        scroll(
            toTextContainerY: lineRect.midY,
            animated: animated,
            preservesExistingTarget: true
        )
    }

    static func lastSpokenReadableCharacterOffset(
        recognizedCharacterCount: Int,
        in prompt: PromptScript
    ) -> Int {
        let recognized = max(0, min(recognizedCharacterCount, prompt.characterCount))
        guard recognized > 0 else { return 0 }
        for word in prompt.words.reversed()
            where !word.isAnnotation && word.characterRange.lowerBound < recognized {
            let upperBound = min(recognized, word.characterRange.upperBound)
            guard upperBound > word.characterRange.lowerBound else { continue }
            let recognizedPrefix = String(
                word.text.prefix(upperBound - word.characterRange.lowerBound)
            )
            var characterOffset = upperBound
            for character in recognizedPrefix.reversed() {
                characterOffset -= 1
                if character.isLetter || character.isNumber {
                    return max(word.characterRange.lowerBound, characterOffset)
                }
            }
        }
        return 0
    }

    private func scroll(
        toTextContainerY textY: CGFloat,
        animated: Bool,
        preservesExistingTarget: Bool = false
    ) {
        let target = textY + textContainerInset.top - effectiveAnchorY
        let maximum = max(0, contentSize.height - bounds.height)
        setProgrammaticContentOffset(
            min(maximum, max(0, target)),
            animated: animated,
            preservesExistingTarget: preservesExistingTarget
        )
    }

    private func setProgrammaticContentOffset(
        _ targetOffset: CGFloat,
        animated: Bool,
        preservesExistingTarget: Bool
    ) {
        let shouldAnimate = PromptScrollAnimation.shouldAnimate(
            requested: animated,
            reduceMotion: UIAccessibility.isReduceMotionEnabled
        )
        guard shouldAnimate else {
            stopScrollDisplayLink()
            setContentOffset(CGPoint(x: 0, y: targetOffset), animated: false)
            return
        }

        let now = CACurrentMediaTime()
        let currentOffset = scrollAnimation?.offset(at: now) ?? contentOffset.y
        if preservesExistingTarget,
           let scrollAnimation,
           abs(scrollAnimation.targetOffset - targetOffset) <= 0.5 {
            return
        }
        let distance = targetOffset - currentOffset
        guard abs(distance) > 0.5 else {
            stopScrollDisplayLink()
            setContentOffset(CGPoint(x: 0, y: targetOffset), animated: false)
            return
        }

        let duration = PromptScrollAnimation.duration(forDistance: distance)
        if let scrollAnimation {
            self.scrollAnimation = scrollAnimation.retargeted(
                to: targetOffset,
                at: now,
                duration: duration
            )
        } else {
            scrollAnimation = PromptScrollAnimation(
                startOffset: currentOffset,
                targetOffset: targetOffset,
                startTime: now,
                duration: duration
            )
        }
        setContentOffset(CGPoint(x: 0, y: currentOffset), animated: false)
        startScrollDisplayLinkIfNeeded()
    }

    private func startScrollDisplayLinkIfNeeded() {
        guard scrollDisplayLink == nil else { return }
        let displayLink = CADisplayLink(
            target: scrollDisplayLinkTarget,
            selector: #selector(PromptScrollDisplayLinkTarget.advance(_:))
        )
        displayLink.add(to: .main, forMode: .common)
        scrollDisplayLink = displayLink
    }

    fileprivate func advanceScrollAnimation(at timestamp: CFTimeInterval) {
        guard let animation = scrollAnimation else {
            stopScrollDisplayLink()
            return
        }
        let offset = animation.offset(at: timestamp)
        setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        if animation.isComplete(at: timestamp) {
            setContentOffset(CGPoint(x: 0, y: animation.targetOffset), animated: false)
            stopScrollDisplayLink()
        }
    }

    private func stopScrollDisplayLink() {
        scrollDisplayLink?.invalidate()
        scrollDisplayLink = nil
        scrollAnimation = nil
    }

    private func scrollLineAnchors(in prompt: PromptScript) -> [LineAnchor] {
        layoutManager.ensureLayout(for: textContainer)
        if !lineAnchors.isEmpty,
           lineAnchorTextLength == textStorage.length,
           abs(lineAnchorWidth - availableTextWidth) <= 0.5 {
            return lineAnchors
        }

        var anchors: [LineAnchor] = []
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            [weak self] _, usedRect, _, lineGlyphRange, _ in
            guard let self else { return }
            let characterRange = self.layoutManager.characterRange(
                forGlyphRange: lineGlyphRange,
                actualGlyphRange: nil
            )
            let characterOffset = Self.characterOffset(
                fromUTF16Offset: characterRange.location,
                in: prompt.text
            )
            anchors.append(
                LineAnchor(
                    wordProgress: prompt.wordProgress(forCharacterOffset: characterOffset),
                    centerY: usedRect.midY
                )
            )
        }
        lineAnchors = anchors
        lineAnchorTextLength = textStorage.length
        lineAnchorWidth = availableTextWidth
        return anchors
    }

    func characterOffset(at location: CGPoint, in prompt: PromptScript) -> Int? {
        guard !prompt.text.isEmpty else { return nil }
        // A recognizer attached to UIScrollView reports its location in the
        // scroll view's bounds coordinate system. That coordinate already
        // includes bounds.origin/contentOffset, so adding contentOffset again
        // selects progressively later words after the user scrolls.
        let point = CGPoint(
            x: location.x - textContainerInset.left,
            y: location.y - textContainerInset.top
        )
        let glyphIndex = layoutManager.glyphIndex(for: point, in: textContainer)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return prompt.characterCount }
        let utf16Offset = layoutManager.characterIndexForGlyph(at: glyphIndex)
        return Self.characterOffset(fromUTF16Offset: utf16Offset, in: prompt.text)
    }

    func characterOffsetAtAnchor(in prompt: PromptScript) -> Int {
        let point = CGPoint(
            x: availableTextWidth * 0.5,
            y: contentOffset.y + effectiveAnchorY - textContainerInset.top
        )
        let glyphIndex = layoutManager.glyphIndex(for: point, in: textContainer)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return prompt.characterCount }
        return Self.characterOffset(
            fromUTF16Offset: layoutManager.characterIndexForGlyph(at: glyphIndex),
            in: prompt.text
        )
    }

    private static func characterOffset(fromUTF16Offset offset: Int, in text: String) -> Int {
        let index = String.Index(utf16Offset: min(offset, text.utf16.count), in: text)
        return text.distance(from: text.startIndex, to: index)
    }

    private var availableTextWidth: CGFloat {
        max(0, bounds.width - textContainerInset.left - textContainerInset.right)
    }
}

private final class PromptScrollDisplayLinkTarget: NSObject {
    weak var textView: PromptUITextView?

    init(textView: PromptUITextView) {
        self.textView = textView
    }

    @objc func advance(_ displayLink: CADisplayLink) {
        guard let textView else {
            displayLink.invalidate()
            return
        }
        textView.advanceScrollAnimation(at: displayLink.timestamp)
    }
}
