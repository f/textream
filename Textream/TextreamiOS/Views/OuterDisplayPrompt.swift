import SwiftUI

/// Shows the script on iPhone Duo's outer display while the camera runs.
///
/// With the device open, the inner display faces the person holding it and
/// the outer display faces the same way as the rear cameras. Showing the
/// script there lets the person being filmed read it, and lets someone record
/// themselves with the rear cameras. The system offers the accessory only
/// while the app fills the inner display with a capture session running, and
/// reports that through `isAvailable`.
struct OuterDisplayPromptAccessory<Prompt: View>: ViewModifier {
    @Binding var isEnabled: Bool
    @Binding var isAvailable: Bool
    let prompt: () -> Prompt

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.sceneAccessory {
                CameraCaptureAccessory(isEnabled: $isEnabled) {
                    prompt()
                }
                .onAvailabilityChange { isAvailable = $0 }
            }
        } else {
            content
        }
    }
}

/// The script as the person in front of the outer display sees it. It reads
/// directly, never mirrored, and follows the session without taking touches,
/// so nobody on that side can move the prompt.
struct OuterDisplayPromptView: View {
    let controller: PromptSessionController
    let settings: PromptDisplaySettings

    var body: some View {
        let configuration = controller.configuration
        let capture = controller.captureController

        VStack(spacing: 0) {
            // A fixed-height header keeps the text from moving when
            // recording starts or stops.
            HStack(spacing: 6) {
                if capture.isActivelyRecording {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text(PromptSessionController.durationString(capture.elapsedRecordingTime))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recording")
            .accessibilityValue(PromptSessionController.durationString(capture.elapsedRecordingTime))
            .accessibilityHidden(!capture.isActivelyRecording)

            PromptTextView(
                prompt: controller.prompt,
                highlightedCharacterCount: controller.effectiveCharacterCount,
                font: configuration.fontFamily.uiFont(
                    size: settings.fontSize.pointSize,
                    weight: .semibold
                ),
                textColor: configuration.textColor.uiColor,
                cueColor: configuration.cueColor.uiColor,
                cueUnreadOpacity: configuration.cueBrightness.unreadOpacity,
                cueReadOpacity: configuration.cueBrightness.readOpacity,
                wordTracking: configuration.followMode == .wordTracking,
                continuousWordProgress: controller.continuousWordProgress,
                allowsHorizontalSpeedAdjustment: false,
                readingPosition: settings.readingPosition,
                topOverlayClearance: 0,
                bottomOverlayClearance: 0,
                horizontalTextInsets: UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16),
                onWordTap: { _ in },
                onManualScrollBegan: {},
                onManualScrollEnded: { _ in },
                onSpeedAdjustmentBegan: {},
                onSpeedAdjustmentChanged: { _, _ in },
                onSpeedAdjustmentEnded: {}
            )
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white, location: 0.06),
                        .init(color: .white, location: 0.9),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .allowsHitTesting(false)
            .accessibilityIdentifier("outerDisplayPromptText")
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

#if DEBUG
/// Renders the outer display's script as the main view, so its layout can be
/// checked on the closed display without a camera to make the accessory
/// available.
struct OuterDisplayPromptPreview: View {
    @State private var controller: PromptSessionController
    private let settings: PromptDisplaySettings

    init(configuration: PromptSessionConfiguration) {
        _controller = State(initialValue: PromptSessionController(configuration: configuration))
        settings = PromptDisplaySettings(configuration: configuration)
    }

    var body: some View {
        OuterDisplayPromptView(controller: controller, settings: settings)
    }
}
#endif
