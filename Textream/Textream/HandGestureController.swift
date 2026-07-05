import AVFoundation
import Vision
import AppKit

@Observable
class HandGestureController: NSObject {
    private static let logFile: FileHandle? = {
        let path = "/tmp/textream_hand.log"
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    static func log(_ msg: String) {
        let line = "\(Date()): \(msg)\n"
        logFile?.seekToEndOfFile()
        logFile?.write(line.data(using: .utf8)!)
    }
    var isHandRaised: Bool = false {
        didSet {
            if isHandRaised != oldValue {
                onHandStateChanged?(isHandRaised, handHeight)
            }
        }
    }
    var handHeight: Float = 0.0  // 0.0 = just above threshold, 1.0 = top of frame

    /// Called on main thread when hand raise state changes. (raised, height)
    var onHandStateChanged: ((Bool, Float) -> Void)?

    private var captureSession: AVCaptureSession?
    private var videoOutput = AVCaptureVideoDataOutput()
    private let processingQueue = DispatchQueue(label: "com.textream.handgesture", qos: .userInteractive)
    private let handPoseRequest = VNDetectHumanHandPoseRequest()

    private let raiseThreshold: Float = 0.25  // wrist Y must exceed this to trigger raise
    private let lowerThreshold: Float = 0.20  // wrist Y must drop below this to trigger lower (hysteresis)
    private var recentWristY: [Float] = []   // rolling buffer for smoothing
    private let smoothingWindow = 4

    private var isRunning = false
    private var frameCount = 0

    override init() {
        super.init()
        handPoseRequest.maximumHandCount = 2
        Self.log("[HandGesture] init()")
    }

    func start() {
        guard !isRunning else {
            Self.log("[HandGesture] start() skipped — already running")
            return
        }

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        Self.log("[HandGesture] start() called, auth status=\(status.rawValue)")
        switch status {
        case .authorized:
            setupAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Self.log("[HandGesture] camera permission granted=\(granted)")
                if granted {
                    DispatchQueue.main.async { self?.setupAndStart() }
                }
            }
        default:
            Self.log("[HandGesture] camera permission denied/restricted")
            return
        }
    }

    func stop() {
        guard isRunning else { return }
        Self.log("[HandGesture] stop()")
        // Clear callback first to prevent triggering rewind logic during teardown
        let savedCallback = onHandStateChanged
        onHandStateChanged = nil

        captureSession?.stopRunning()
        captureSession = nil  // release session so videoOutput can be re-added later
        isRunning = false
        isHandRaised = false
        handHeight = 0.0
        recentWristY = []

        // Restore callback for next start
        onHandStateChanged = savedCallback
    }

    private func setupAndStart() {
        Self.log("[HandGesture] setupAndStart()")
        let session = AVCaptureSession()
        session.sessionPreset = .low

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video) else {
            Self.log("[HandGesture] No camera found")
            return
        }
        Self.log("[HandGesture] Using camera: \(camera.localizedName)")

        guard let input = try? AVCaptureDeviceInput(device: camera) else {
            Self.log("[HandGesture] Failed to create camera input")
            return
        }
        guard session.canAddInput(input) else {
            Self.log("[HandGesture] Cannot add input to session")
            return
        }
        session.addInput(input)

        videoOutput = AVCaptureVideoDataOutput()
        videoOutput.setSampleBufferDelegate(self, queue: processingQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(videoOutput) else {
            Self.log("[HandGesture] Cannot add output to session")
            return
        }
        session.addOutput(videoOutput)

        captureSession = session

        processingQueue.async {
            session.startRunning()
            Self.log("[HandGesture] session.startRunning() completed")
        }
        isRunning = true
    }
}

extension HandGestureController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameCount += 1
        if frameCount % 30 == 1 {
            Self.log("[HandGesture] frame \(frameCount) received")
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([handPoseRequest])

        guard let results = handPoseRequest.results, !results.isEmpty else {
            DispatchQueue.main.async {
                self.updateWristPosition(nil)
            }
            return
        }

        // Find the hand with the highest wrist Y
        var highestWristY: Float = 0
        for hand in results {
            if let wrist = try? hand.recognizedPoint(.wrist),
               wrist.confidence > 0.3 {
                let y = Float(wrist.location.y)
                Self.log("[HandGesture] wrist y=\(String(format: "%.3f", y)) conf=\(String(format: "%.2f", wrist.confidence))")
                if y > highestWristY {
                    highestWristY = y
                }
            }
        }

        DispatchQueue.main.async {
            self.updateWristPosition(highestWristY > 0 ? highestWristY : nil)
        }
    }

    private func updateWristPosition(_ wristY: Float?) {
        guard let y = wristY else {
            recentWristY = []
            handHeight = 0.0
            isHandRaised = false  // set after height so callback has correct height
            return
        }

        recentWristY.append(y)
        if recentWristY.count > smoothingWindow {
            recentWristY.removeFirst()
        }
        let smoothed = recentWristY.reduce(0, +) / Float(recentWristY.count)

        // Hysteresis: raise at raiseThreshold, lower at lowerThreshold
        if !isHandRaised && smoothed > raiseThreshold {
            Self.log("[HandGesture] HAND RAISED (smoothed=\(String(format: "%.3f", smoothed)))")
            handHeight = min(1.0, (smoothed - lowerThreshold) / (1.0 - lowerThreshold))
            isHandRaised = true
        } else if isHandRaised && smoothed < lowerThreshold {
            Self.log("[HandGesture] HAND LOWERED (smoothed=\(String(format: "%.3f", smoothed)))")
            handHeight = 0.0
            isHandRaised = false
        } else if isHandRaised {
            // Update height while raised (for speed control)
            handHeight = min(1.0, (smoothed - lowerThreshold) / (1.0 - lowerThreshold))
        }
    }
}
