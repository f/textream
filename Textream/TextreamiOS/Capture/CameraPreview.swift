@preconcurrency import AVFoundation
import QuartzCore
import SwiftUI
import UIKit

struct CameraRotationState {
    private(set) var previewAngle: CGFloat?
    private(set) var captureAngle: CGFloat?

    mutating func consumePreviewAngle(_ angle: CGFloat) -> CGFloat? {
        guard Self.shouldApply(angle, after: previewAngle) else { return nil }
        previewAngle = angle
        return angle
    }

    mutating func consumeCaptureAngle(_ angle: CGFloat) -> CGFloat? {
        guard Self.shouldApply(angle, after: captureAngle) else { return nil }
        captureAngle = angle
        return angle
    }

    mutating func reset() {
        previewAngle = nil
        captureAngle = nil
    }

    private static func shouldApply(_ angle: CGFloat, after previousAngle: CGFloat?) -> Bool {
        previousAngle.map { abs($0 - angle) > 0.5 } ?? true
    }
}

struct CameraPreview: UIViewRepresentable {
    let controller: CaptureController

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.configure(controller: controller)
        return view
    }

    func updateUIView(_ view: CameraPreviewView, context: Context) {
        view.configure(controller: controller)
        view.refreshRotation()
    }
}

@MainActor
final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    private var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    private weak var controller: CaptureController?
    private var configuredDeviceID: String?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewAngleObservation: NSKeyValueObservation?
    private var captureAngleObservation: NSKeyValueObservation?
    private var rotationObservationGeneration = 0
    private var rotationState = CameraRotationState()
    private var lastMirroredPosition: AVCaptureDevice.Position?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        previewAngleObservation?.invalidate()
        captureAngleObservation?.invalidate()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            invalidateRotationCoordinator()
            return
        }
        installRotationCoordinatorIfPossible()
        refreshRotation()
    }

    func configure(controller: CaptureController) {
        self.controller = controller
        if previewLayer.session !== controller.session {
            previewLayer.session = controller.session
        }

        let device = controller.activeVideoDevice
        if configuredDeviceID != device?.uniqueID {
            invalidateRotationCoordinator()
            configuredDeviceID = device?.uniqueID
        }
        installRotationCoordinatorIfPossible()
        refreshRotation()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshRotation()
    }

    func refreshRotation() {
        guard let rotationCoordinator else { return }
        let generation = rotationObservationGeneration
        applyPreviewAngle(
            rotationCoordinator.videoRotationAngleForHorizonLevelPreview,
            generation: generation
        )
        applyCaptureAngle(
            rotationCoordinator.videoRotationAngleForHorizonLevelCapture,
            generation: generation
        )
    }

    private func installRotationCoordinator(for device: AVCaptureDevice) {
        let coordinator = AVCaptureDevice.RotationCoordinator(
            device: device,
            previewLayer: previewLayer
        )
        rotationCoordinator = coordinator
        let generation = rotationObservationGeneration

        previewAngleObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.initial, .new]
        ) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            // RotationCoordinator delivers KVO updates on the main queue. Apply
            // synchronously so successive angles cannot be reordered by Tasks.
            MainActor.assumeIsolated { [weak self] in
                self?.applyPreviewAngle(angle, generation: generation)
            }
        }

        captureAngleObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture,
            options: [.initial, .new]
        ) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            MainActor.assumeIsolated { [weak self] in
                self?.applyCaptureAngle(angle, generation: generation)
            }
        }
    }

    private func installRotationCoordinatorIfPossible() {
        guard window != nil,
              rotationCoordinator == nil,
              let device = controller?.activeVideoDevice,
              device.uniqueID == configuredDeviceID else { return }
        installRotationCoordinator(for: device)
    }

    private func invalidateRotationCoordinator() {
        rotationObservationGeneration &+= 1
        previewAngleObservation?.invalidate()
        captureAngleObservation?.invalidate()
        previewAngleObservation = nil
        captureAngleObservation = nil
        rotationCoordinator = nil
        rotationState.reset()
        lastMirroredPosition = nil
    }

    private func applyPreviewAngle(_ angle: CGFloat, generation: Int) {
        guard generation == rotationObservationGeneration,
              let controller,
              let connection = previewLayer.connection else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if connection.isVideoRotationAngleSupported(angle),
           let angle = rotationState.consumePreviewAngle(angle) {
            connection.videoRotationAngle = angle
        }

        if connection.isVideoMirroringSupported,
           lastMirroredPosition != controller.cameraPosition {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = controller.cameraPosition == .front
            lastMirroredPosition = controller.cameraPosition
        }
    }

    private func applyCaptureAngle(_ angle: CGFloat, generation: Int) {
        guard generation == rotationObservationGeneration,
              let controller,
              let angle = rotationState.consumeCaptureAngle(angle) else { return }
        controller.setCaptureRotationAngle(angle)
    }
}
