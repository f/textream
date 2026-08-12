@preconcurrency import AVFoundation
import Foundation

enum AudioSampleLevelMeter {
    /// Reads the microphone's linear PCM samples directly. AVCaptureAudioChannel
    /// metering is not guaranteed to be populated for an
    /// AVCaptureAudioDataOutput connection, which can otherwise leave Voice
    /// mode permanently below its activation threshold on a physical device.
    nonisolated static func normalizedRMS(from sampleBuffer: CMSampleBuffer) -> CGFloat? {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              description.mFormatID == kAudioFormatLinearPCM else { return nil }

        var audioBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)
        )
        var retainedBlockBuffer: CMBlockBuffer?
        let status = withUnsafeMutablePointer(to: &audioBufferList) { bufferListPointer in
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: bufferListPointer,
                bufferListSize: MemoryLayout<AudioBufferList>.size,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
                blockBufferOut: &retainedBlockBuffer
            )
        }
        guard status == noErr, let data = audioBufferList.mBuffers.mData else { return nil }

        let byteCount = Int(audioBufferList.mBuffers.mDataByteSize)
        let flags = description.mFormatFlags
        if flags & kAudioFormatFlagIsFloat != 0 {
            switch description.mBitsPerChannel {
            case 32:
                let samples = UnsafeBufferPointer(
                    start: data.assumingMemoryBound(to: Float.self),
                    count: byteCount / MemoryLayout<Float>.size
                )
                return normalizedRMS(samples.lazy.map(Double.init))
            case 64:
                let samples = UnsafeBufferPointer(
                    start: data.assumingMemoryBound(to: Double.self),
                    count: byteCount / MemoryLayout<Double>.size
                )
                return normalizedRMS(samples.lazy)
            default:
                return nil
            }
        }

        guard flags & kAudioFormatFlagIsSignedInteger != 0 else { return nil }
        switch description.mBitsPerChannel {
        case 16:
            let samples = UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: Int16.self),
                count: byteCount / MemoryLayout<Int16>.size
            )
            return normalizedRMS(samples.lazy.map { Double($0) / 32_768 })
        case 32:
            let samples = UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: Int32.self),
                count: byteCount / MemoryLayout<Int32>.size
            )
            return normalizedRMS(samples.lazy.map { Double($0) / 2_147_483_648 })
        default:
            return nil
        }
    }

    nonisolated static func normalizedRMS<S: Sequence>(_ samples: S) -> CGFloat where S.Element == Double {
        var squaredTotal = 0.0
        var count = 0
        for sample in samples {
            guard sample.isFinite else { continue }
            squaredTotal += sample * sample
            count += 1
        }
        guard count > 0 else { return 0 }
        return CGFloat(min(1, sqrt(squaredTotal / Double(count))))
    }
}

struct VoiceActivityDetector {
    private let activationLevel: CGFloat
    private let immediateActivationLevel: CGFloat
    private let requiredActiveFrames: Int
    private let hangoverDuration: TimeInterval
    private var consecutiveActiveFrames = 0
    private var activeUntil = -TimeInterval.infinity

    init(
        activationLevel: CGFloat = 0.012,
        immediateActivationLevel: CGFloat = 0.04,
        requiredActiveFrames: Int = 2,
        hangoverDuration: TimeInterval = 0.75
    ) {
        self.activationLevel = activationLevel
        self.immediateActivationLevel = immediateActivationLevel
        self.requiredActiveFrames = requiredActiveFrames
        self.hangoverDuration = hangoverDuration
    }

    mutating func process(level: CGFloat, at timestamp: TimeInterval) {
        if level >= immediateActivationLevel {
            consecutiveActiveFrames = requiredActiveFrames
            extendActivity(at: timestamp)
        } else if level >= activationLevel {
            consecutiveActiveFrames += 1
            if consecutiveActiveFrames >= requiredActiveFrames { extendActivity(at: timestamp) }
        } else {
            consecutiveActiveFrames = 0
        }
    }

    func isActive(at timestamp: TimeInterval) -> Bool { timestamp < activeUntil }

    mutating func reset() {
        consecutiveActiveFrames = 0
        activeUntil = -TimeInterval.infinity
    }

    private mutating func extendActivity(at timestamp: TimeInterval) {
        activeUntil = max(activeUntil, timestamp + hangoverDuration)
    }
}
