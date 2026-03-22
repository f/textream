import XCTest
@testable import Textream

@MainActor
final class PerformanceBaselineTests: XCTestCase {
    private static let retainedAnchorService = WindowAnchorService(provider: UITestRuntimeSupport.anchorProvider)

    func testTrackingDecisionLatencyBaseline() {
        var guarder = TrackingGuard(text: "one two three four five six seven eight nine ten eleven twelve")
        let frame = SpeechRecognitionFrame(
            partialText: "one two three four five",
            segments: [
                SpeechSegmentSnapshot(text: "one", confidence: 0.93, timestamp: 0.0, duration: 0.08),
                SpeechSegmentSnapshot(text: "two", confidence: 0.94, timestamp: 0.1, duration: 0.08),
                SpeechSegmentSnapshot(text: "three", confidence: 0.95, timestamp: 0.2, duration: 0.08),
                SpeechSegmentSnapshot(text: "four", confidence: 0.94, timestamp: 0.3, duration: 0.08),
                SpeechSegmentSnapshot(text: "five", confidence: 0.93, timestamp: 0.4, duration: 0.08),
            ],
            isFinal: false,
            createdAt: Date()
        )

        measure(metrics: [XCTClockMetric()]) {
            guarder.reset(with: "one two three four five six seven eight nine ten eleven twelve")
            _ = guarder.process(
                frame: frame,
                isSpeaking: true,
                strictTrackingEnabled: true,
                advanceThreshold: 3.0,
                windowSize: 8,
                offScriptFreezeDelay: 1.0,
                useLegacyFallback: false
            )
        }
    }

    func testOverlayStatePropagationLatencyBaseline() {
        let snapshot = TrackingSnapshot(
            highlightedCharCount: 24,
            trackingState: .tracking,
            expectedWord: "overlay",
            nextCue: "state propagation stays fast",
            confidenceLevel: .high,
            manualAsideMode: .inactive,
            statusLine: "Tracking: overlay",
            confidenceScore: 4.1,
            decisionReason: .advanced,
            debugSummary: "Performance baseline"
        )
        let frame = SpeechRecognitionFrame(
            partialText: "overlay state propagation",
            segments: [
                SpeechSegmentSnapshot(text: "overlay", confidence: 0.9, timestamp: 0, duration: 0.1),
            ],
            isFinal: false,
            createdAt: Date()
        )

        measure(metrics: [XCTClockMetric()]) {
            _ = OverlayStateProjector.projected(snapshot: snapshot, frame: frame)
        }
    }

    func testWindowAnchorUpdateFrequencyCPUCostBaseline() {
        let provider = UITestRuntimeSupport.anchorProvider
        provider.reset()
        let service = Self.retainedAnchorService
        let overlaySize = CGSize(width: 260, height: 120)

        measure(metrics: [XCTClockMetric(), XCTCPUMetric()]) {
            for _ in 0..<120 {
                provider.shiftWindow(dx: 4, dy: -2)
                let resolution = service.resolution(for: UITestRuntimeSupport.mockWindowID)
                guard let frame = resolution.frame else {
                    XCTFail("Expected mock anchor frame during performance baseline")
                    return
                }
                _ = service.anchoredOrigin(
                    targetFrame: frame,
                    overlaySize: overlaySize,
                    corner: .topRight,
                    marginX: 16,
                    marginY: 12
                )
            }
        }
    }
}
