import XCTest
@testable import Textream

private struct MockWindowAnchorProvider: WindowAnchorProviding {
    var accessibilityTrusted: Bool
    var windows: [AttachedWindowInfo]
    var accessibilityFrames: [Int: CGRect]

    func isAccessibilityTrusted(prompt _: Bool) -> Bool {
        accessibilityTrusted
    }

    func openAccessibilitySettings() {}

    func visibleWindows() -> [AttachedWindowInfo] {
        windows
    }

    func accessibilityFrame(for target: AttachedWindowInfo) -> CGRect? {
        accessibilityFrames[target.id]
    }
}

final class WindowAnchorServiceTests: XCTestCase {
    func testResolutionUsesAccessibilityGeometryWhenAvailable() {
        let visibleBounds = CGRect(x: 240, y: 320, width: 640, height: 420)
        let accessibilityBounds = CGRect(x: 248, y: 328, width: 632, height: 408)
        let window = AttachedWindowInfo(
            id: 7,
            ownerName: "Preview",
            title: "Presenter Notes",
            pid: 42,
            bounds: visibleBounds,
            layer: 0,
            isOnScreen: true
        )
        let service = WindowAnchorService(
            provider: MockWindowAnchorProvider(
                accessibilityTrusted: true,
                windows: [window],
                accessibilityFrames: [window.id: accessibilityBounds]
            )
        )

        let resolution = service.resolution(for: window.id)

        XCTAssertEqual(resolution.source, .accessibility)
        XCTAssertEqual(resolution.window?.id, window.id)
        XCTAssertEqual(resolution.frame, accessibilityBounds)
        XCTAssertTrue(resolution.isAccessibilityTrusted)
    }

    func testResolutionFallsBackToQuartzWhenAccessibilityFrameIsMissing() {
        let visibleBounds = CGRect(x: 240, y: 320, width: 640, height: 420)
        let window = AttachedWindowInfo(
            id: 8,
            ownerName: "Preview",
            title: "Presenter Notes",
            pid: 42,
            bounds: visibleBounds,
            layer: 0,
            isOnScreen: true
        )
        let service = WindowAnchorService(
            provider: MockWindowAnchorProvider(
                accessibilityTrusted: true,
                windows: [window],
                accessibilityFrames: [:]
            )
        )

        let resolution = service.resolution(for: window.id)

        XCTAssertEqual(resolution.source, .quartz)
        XCTAssertEqual(resolution.window?.id, window.id)
        XCTAssertEqual(resolution.frame, visibleBounds)
        XCTAssertTrue(resolution.isAccessibilityTrusted)
    }

    func testAnchoredOriginRespectsTopRightCorner() {
        let service = WindowAnchorService()
        let origin = service.anchoredOrigin(
            targetFrame: CGRect(x: 100, y: 200, width: 500, height: 300),
            overlaySize: CGSize(width: 200, height: 100),
            corner: .topRight,
            marginX: 16,
            marginY: 12
        )

        XCTAssertEqual(origin.x, 384, accuracy: 0.001)
        XCTAssertEqual(origin.y, 388, accuracy: 0.001)
    }

    func testFallbackFrameKeepsRequestedSize() {
        let service = WindowAnchorService()
        let frame = service.fallbackFrame(
            overlaySize: CGSize(width: 320, height: 180),
            corner: .bottomLeft,
            marginX: 20,
            marginY: 24,
            on: nil
        )

        XCTAssertEqual(frame.width, 320, accuracy: 0.001)
        XCTAssertEqual(frame.height, 180, accuracy: 0.001)
    }

    func testAnchoredOriginClampsTopRightInsideVisibleFrame() {
        let service = WindowAnchorService()
        let origin = service.anchoredOrigin(
            targetFrame: CGRect(x: 900, y: 520, width: 280, height: 260),
            overlaySize: CGSize(width: 200, height: 100),
            corner: .topRight,
            marginX: 16,
            marginY: 12,
            within: CGRect(x: 0, y: 24, width: 1000, height: 676)
        )

        XCTAssertEqual(origin.x, 800, accuracy: 0.001)
        XCTAssertEqual(origin.y, 600, accuracy: 0.001)
    }

    func testAnchoredOriginClampsBottomLeftInsideVisibleFrame() {
        let service = WindowAnchorService()
        let origin = service.anchoredOrigin(
            targetFrame: CGRect(x: -80, y: -120, width: 360, height: 260),
            overlaySize: CGSize(width: 240, height: 110),
            corner: .bottomLeft,
            marginX: 18,
            marginY: 14,
            within: CGRect(x: 0, y: 24, width: 1280, height: 776)
        )

        XCTAssertEqual(origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(origin.y, 24, accuracy: 0.001)
    }

    func testAnchoredOriginKeepsTopEdgeTightBeforeFinalClamp() {
        let service = WindowAnchorService()
        let origin = service.anchoredOrigin(
            targetFrame: CGRect(x: 100, y: 560, width: 500, height: 180),
            overlaySize: CGSize(width: 200, height: 100),
            corner: .topRight,
            marginX: 16,
            marginY: 12,
            within: CGRect(x: 0, y: 24, width: 1000, height: 676)
        )

        XCTAssertEqual(origin.x, 384, accuracy: 0.001)
        XCTAssertEqual(origin.y, 600, accuracy: 0.001)
    }

    func testAnchoredOriginKeepsBottomEdgeTightBeforeFinalClamp() {
        let service = WindowAnchorService()
        let origin = service.anchoredOrigin(
            targetFrame: CGRect(x: 100, y: 10, width: 500, height: 240),
            overlaySize: CGSize(width: 200, height: 100),
            corner: .bottomLeft,
            marginX: 18,
            marginY: 14,
            within: CGRect(x: 0, y: 24, width: 1280, height: 776)
        )

        XCTAssertEqual(origin.x, 118, accuracy: 0.001)
        XCTAssertEqual(origin.y, 24, accuracy: 0.001)
    }

    func testNormalizeUpperLeftDesktopCoordinatesToAppKitCoordinates() {
        let normalized = LiveWindowAnchorProvider.normalizeToAppKitCoordinates(
            CGRect(x: 120, y: 40, width: 500, height: 300),
            desktopFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )

        XCTAssertEqual(normalized.origin.x, 120, accuracy: 0.001)
        XCTAssertEqual(normalized.origin.y, 560, accuracy: 0.001)
        XCTAssertEqual(normalized.width, 500, accuracy: 0.001)
        XCTAssertEqual(normalized.height, 300, accuracy: 0.001)
    }

    func testNormalizeUpperLeftCoordinatesAcrossDesktopUnion() {
        let normalized = LiveWindowAnchorProvider.normalizeToAppKitCoordinates(
            CGRect(x: -1500, y: 920, width: 640, height: 360),
            desktopFrame: CGRect(x: -1728, y: -1080, width: 3168, height: 1980)
        )

        XCTAssertEqual(normalized.origin.x, -1500, accuracy: 0.001)
        XCTAssertEqual(normalized.origin.y, -380, accuracy: 0.001)
        XCTAssertEqual(normalized.width, 640, accuracy: 0.001)
        XCTAssertEqual(normalized.height, 360, accuracy: 0.001)
    }
}
