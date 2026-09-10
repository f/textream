import AppKit

/// Window coordinates are stored separately from the pinned overlay dimensions.
enum FloatingWindowGeometry {
    static let minimumSize = NSSize(width: 280, height: 180)
    static let defaultSize = NSSize(width: 720, height: 420)

    static func decode(_ value: String) -> NSRect? {
        let frame = NSRectFromString(value)
        return isValid(frame) ? frame : nil
    }

    static func isValid(_ frame: NSRect) -> Bool {
        [frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy(\.isFinite)
            && frame.width > 0 && frame.height > 0
    }

    static func restoredFrame(
        saved: NSRect?,
        visibleFrames: [NSRect],
        fallback: NSRect
    ) -> NSRect {
        let saved = saved.flatMap { isValid($0) ? $0 : nil }
        let frame = saved ?? NSRect(
            x: fallback.midX - defaultSize.width / 2,
            y: fallback.midY - defaultSize.height / 2,
            width: defaultSize.width,
            height: defaultSize.height
        )
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let screen = visibleFrames.first(where: { $0.contains(center) }) ?? fallback
        let width = min(screen.width, max(minimumSize.width, frame.width))
        let height = min(screen.height, max(minimumSize.height, frame.height))

        return NSRect(
            x: min(max(frame.minX, screen.minX), screen.maxX - width),
            y: min(max(frame.minY, screen.minY), screen.maxY - height),
            width: width,
            height: height
        )
    }
}
