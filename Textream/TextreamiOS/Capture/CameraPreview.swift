@preconcurrency import AVFoundation
import AVKit
import QuartzCore
import SwiftUI
import UIKit

/// Which cameras face the person looking at the preview.
///
/// On iPhone Duo a camera's position no longer says which way it points: a
/// rear camera faces the viewer when the device is folded around, and the
/// front camera can be the inner or the outer one. The direction coordinator
/// reports the cameras on each side; until it does, and on devices where it
/// reports nothing, the front camera is the one facing the viewer.
struct CameraFacing: Equatable {
    var forwardDeviceIDs: Set<String> = []
    var backwardDeviceIDs: Set<String> = []

    /// A preview reads as a mirror only when its camera faces the viewer.
    func previewIsMirrored(deviceID: String?, position: AVCaptureDevice.Position) -> Bool {
        if let deviceID {
            if forwardDeviceIDs.contains(deviceID) { return true }
            if backwardDeviceIDs.contains(deviceID) { return false }
        }
        return position == .front
    }
}

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
    private var lastMirrored: Bool?
    /// An `AVCaptureDeviceDirectionCoordinator` on iOS 27.1 and later.
    private var directionCoordinator: AnyObject?
    private var cameraFacing = CameraFacing()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        // Aspect fill draws past the layer's bounds. Clip it so a preview that
        // holds only one half of a folded display stays out of the other half.
        clipsToBounds = true
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
            directionCoordinator = nil
            cameraFacing = CameraFacing()
            return
        }
        installDirectionCoordinatorIfPossible()
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
        lastMirrored = nil
    }

    private func installDirectionCoordinatorIfPossible() {
        guard #available(iOS 27.1, *), window != nil, directionCoordinator == nil else { return }
        // The handler runs on the main queue: once with the first map, then
        // whenever a fold or unfold changes which cameras face the viewer.
        directionCoordinator = AVCaptureDeviceDirectionCoordinator(
            view: self,
            deviceTypes: CaptureController.preferredCameraDeviceTypes
        ) { [weak self] directions in
            let facing = CameraFacing(
                forwardDeviceIDs: Set(directions.forwardFacingDeviceDescriptors.map(\.uniqueID)),
                backwardDeviceIDs: Set(directions.backwardFacingDeviceDescriptors.map(\.uniqueID))
            )
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.cameraFacing != facing else { return }
                self.cameraFacing = facing
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.applyMirroring()
                CATransaction.commit()
            }
        }
    }

    private func applyMirroring() {
        guard let controller,
              let connection = previewLayer.connection,
              connection.isVideoMirroringSupported else { return }
        let mirrored = cameraFacing.previewIsMirrored(
            deviceID: controller.activeVideoDevice?.uniqueID,
            position: controller.cameraPosition
        )
        guard lastMirrored != mirrored else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
        lastMirrored = mirrored
    }

    private func applyPreviewAngle(_ angle: CGFloat, generation: Int) {
        guard generation == rotationObservationGeneration,
              let connection = previewLayer.connection else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if connection.isVideoRotationAngleSupported(angle),
           let angle = rotationState.consumePreviewAngle(angle) {
            connection.videoRotationAngle = angle
        }

        applyMirroring()
    }

    private func applyCaptureAngle(_ angle: CGFloat, generation: Int) {
        guard generation == rotationObservationGeneration,
              let controller,
              let angle = rotationState.consumeCaptureAngle(angle) else { return }
        controller.setCaptureRotationAngle(angle)
    }
}
