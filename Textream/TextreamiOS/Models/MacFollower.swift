import Foundation
import Observation

/// Follows a Textream session running on a Mac over the local network.
///
/// The Mac's Remote Connection server broadcasts its live state over a
/// WebSocket on `httpPort + 1`: the script as words, how many characters
/// have been spoken, and whether a session is active. This client consumes
/// that feed so the phone can render it in the native prompter, with the
/// Mac's microphone doing the word tracking.
@Observable
@MainActor
final class MacFollower {
    /// What the Mac is showing right now, decoded from its broadcast.
    struct State: Decodable, Equatable {
        var words: [String]
        var highlightedCharCount: Int
        var totalCharCount: Int
        var isListening: Bool
        var isDone: Bool
        var isActive: Bool
        var lastSpokenText: String
    }

    enum Connection: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    private(set) var connection: Connection = .idle
    private(set) var state: State?
    /// The Mac's HTTP address as shown in its QR code, e.g. 192.168.0.12:7373.
    private(set) var address: String?

    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var receiveLoop: Task<Void, Never>?
    @ObservationIgnored private var reconnectAttempts = 0

    var isConnected: Bool { connection == .connected }

    /// The Mac's script, in the same collapsed form the Mac counts characters in.
    var scriptText: String { state?.words.joined(separator: " ") ?? "" }

    var highlightedCharacterCount: Int {
        guard let state else { return 0 }
        return max(0, min(state.highlightedCharCount, state.totalCharCount))
    }

    var hasScript: Bool { !(state?.words.isEmpty ?? true) }

    var statusText: String {
        switch connection {
        case .idle: "Not connected"
        case .connecting: "Connecting to Mac…"
        case .connected:
            if let state, state.isActive {
                state.isListening ? "Following the Mac" : "Mac is paused"
            } else {
                "Connected — start reading on the Mac"
            }
        case .failed(let message): message
        }
    }

    /// Accepts the QR code's URL (`http://host:port`) or a bare `host:port`.
    /// Returns the WebSocket URL, which lives one port above the HTTP one.
    nonisolated static func webSocketURL(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "http://" + text }
        guard let url = URL(string: text), let host = url.host, !host.isEmpty else { return nil }
        let httpPort = url.port ?? 7373
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = httpPort + 1
        return components.url
    }

    func connect(to input: String) {
        guard let url = Self.webSocketURL(from: input) else {
            connection = .failed("That does not look like a Textream address.")
            return
        }
        disconnect()
        address = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "http://", with: "")
        reconnectAttempts = 0
        open(url)
    }

    func disconnect() {
        receiveLoop?.cancel()
        receiveLoop = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        connection = .idle
        state = nil
    }

    private func open(_ url: URL) {
        connection = .connecting
        let socket = URLSession.shared.webSocketTask(with: url)
        task = socket
        socket.resume()
        receiveLoop = Task { [weak self] in
            await self?.receive(on: socket, url: url)
        }
    }

    private func receive(on socket: URLSessionWebSocketTask, url: URL) async {
        let decoder = JSONDecoder()
        while !Task.isCancelled, task === socket {
            do {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .data(let d): data = d
                case .string(let s): data = Data(s.utf8)
                @unknown default: continue
                }
                if let decoded = try? decoder.decode(State.self, from: data) {
                    if connection != .connected { connection = .connected }
                    reconnectAttempts = 0
                    if decoded != state { state = decoded }
                }
            } catch {
                guard !Task.isCancelled, task === socket else { return }
                // Dropped — Wi-Fi blip or the Mac stopped Remote. Back off and retry.
                reconnectAttempts += 1
                connection = reconnectAttempts > 8
                    ? .failed("Lost the Mac. Check Remote is on and both are on the same Wi-Fi.")
                    : .connecting
                guard reconnectAttempts <= 8 else { return }
                try? await Task.sleep(for: .seconds(min(5, Double(reconnectAttempts))))
                guard !Task.isCancelled, task === socket else { return }
                open(url)
                return
            }
        }
    }
}
