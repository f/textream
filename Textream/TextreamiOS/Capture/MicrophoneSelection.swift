import AVFoundation
import Foundation

/// Which microphone the capture session should use.
///
/// `AVCaptureDevice.default(for: .audio)` on iOS is always the built-in mic;
/// the audio that actually arrives comes from `AVAudioSession`'s current
/// input route. Nothing selected that route, so AirPods, USB receivers such
/// as a Hollyland Lark, and wired headsets were available but never used.
enum MicrophoneSelection: Equatable {
    /// Prefer an external microphone when one is connected, else built-in.
    case automatic
    /// A specific input, by `AVAudioSessionPortDescription.uid`.
    case port(uid: String)

    static let defaultsKey = "ios.microphoneUID"

    static func load(from defaults: UserDefaults = .standard) -> MicrophoneSelection {
        if let uid = defaults.string(forKey: defaultsKey), !uid.isEmpty { return .port(uid: uid) }
        return .automatic
    }

    func save(to defaults: UserDefaults = .standard) {
        switch self {
        case .automatic: defaults.removeObject(forKey: Self.defaultsKey)
        case .port(let uid): defaults.set(uid, forKey: Self.defaultsKey)
        }
    }

    /// Resolves the selection against the inputs currently available.
    /// A remembered port that is not connected falls back to automatic.
    nonisolated static func resolve(
        _ selection: MicrophoneSelection,
        among inputs: [AVAudioSessionPortDescription]
    ) -> AVAudioSessionPortDescription? {
        if case .port(let uid) = selection, let match = inputs.first(where: { $0.uid == uid }) {
            return match
        }
        return inputs.first { $0.portType != .builtInMic } ?? inputs.first { $0.portType == .builtInMic }
    }

    /// Applies the selection to the shared audio session. Safe to call
    /// repeatedly; it is a no-op when the chosen port is already active.
    static func apply(_ selection: MicrophoneSelection) {
        let audioSession = AVAudioSession.sharedInstance()
        guard let inputs = audioSession.availableInputs,
              let chosen = resolve(selection, among: inputs) else { return }
        if audioSession.currentRoute.inputs.contains(where: { $0.uid == chosen.uid }) { return }
        try? audioSession.setPreferredInput(chosen)
    }

    /// Human-readable name of the input currently feeding the session.
    static var activeInputName: String? {
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName
    }
}
