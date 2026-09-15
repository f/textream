//
//  ModelDownloadManager.swift
//  Textream
//
//  Downloads catalog models straight from Hugging Face into the app's models
//  directory. Hugging Face is the only source: there is no mirror and no
//  bundled copy, so a failure is reported instead of being papered over.
//
//  Each transfer writes to `<filename>.partial` and resumes it with a `Range`
//  header, verifies the catalog SHA-256, and only then renames the file into
//  place. That order means a half-written or corrupt file can never be offered
//  to the engine as a usable model.
//

import Foundation
import CryptoKit

enum ModelDownloadState: Equatable {
    case queued
    case downloading(received: UInt64, total: UInt64, bytesPerSecond: Double)
    case verifying
    case failed(String)

    var isActive: Bool {
        switch self {
        case .queued, .downloading, .verifying: return true
        case .failed: return false
        }
    }

    var percentage: Double {
        guard case .downloading(let received, let total, _) = self, total > 0 else { return 0 }
        return min(100, Double(received) / Double(total) * 100)
    }
}

@Observable
@MainActor
final class ModelDownloadManager {
    static let shared = ModelDownloadManager()

    /// Live state per catalog filename. Absence means "not downloading".
    private(set) var states: [String: ModelDownloadState] = [:]

    private var tasks: [String: Task<Void, Never>] = [:]

    private init() {}

    func state(for filename: String) -> ModelDownloadState? { states[filename] }

    var hasActiveDownload: Bool { states.values.contains { $0.isActive } }

    /// Combined byte progress (0–1) across every running transfer, so the
    /// settings summary can show one number for several downloads.
    var overallProgress: Double {
        var received: UInt64 = 0
        var total: UInt64 = 0
        for state in states.values {
            guard case .downloading(let got, let want, _) = state else { continue }
            received += got
            total += want
        }
        guard total > 0 else { return 0 }
        return Double(received) / Double(total)
    }

    static func byteRate(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    // MARK: - Control

    func download(_ model: CatalogModel, file: CatalogQuantFile) {
        guard tasks[file.filename] == nil else { return }
        states[file.filename] = .queued

        let task = Task { [weak self] in
            do {
                try await Self.perform(model: model, file: file) { received, total, speed in
                    Task { @MainActor [weak self] in
                        guard self?.tasks[file.filename] != nil else { return }
                        self?.states[file.filename] = .downloading(received: received, total: total, bytesPerSecond: speed)
                    }
                } onVerify: {
                    Task { @MainActor [weak self] in
                        guard self?.tasks[file.filename] != nil else { return }
                        self?.states[file.filename] = .verifying
                    }
                }
                await MainActor.run { [weak self] in
                    self?.tasks[file.filename] = nil
                    self?.states[file.filename] = nil
                    LocalSpeechModelStore.shared.refresh()
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    self?.tasks[file.filename] = nil
                    self?.states[file.filename] = nil
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { [weak self] in
                    self?.tasks[file.filename] = nil
                    self?.states[file.filename] = .failed(message)
                }
            }
        }
        tasks[file.filename] = task
    }

    /// Stops the transfer but keeps the partial file, so the next attempt resumes.
    func cancel(_ filename: String) {
        tasks[filename]?.cancel()
        tasks[filename] = nil
        states[filename] = nil
    }

    /// Cancels and removes the partial file, discarding the downloaded bytes.
    func discardPartial(_ filename: String) {
        cancel(filename)
        try? FileManager.default.removeItem(at: Self.partialURL(for: filename))
    }

    func clearError(_ filename: String) {
        if case .failed = states[filename] { states[filename] = nil }
    }

    /// Bytes already downloaded for an unfinished transfer, for a resume hint.
    nonisolated static func partialSize(for filename: String) -> UInt64 {
        let values = try? partialURL(for: filename).resourceValues(forKeys: [.fileSizeKey])
        return UInt64(values?.fileSize ?? 0)
    }

    nonisolated static func partialURL(for filename: String) -> URL {
        LocalSpeechModelStore.modelsDirectory.appendingPathComponent(filename + ".partial")
    }

    // MARK: - Transfer

    private static let connectTimeout: TimeInterval = 15
    private static let stallTimeout: TimeInterval = 60

    private nonisolated static func perform(
        model: CatalogModel,
        file: CatalogQuantFile,
        onProgress: @escaping (UInt64, UInt64, Double) -> Void,
        onVerify: @escaping () -> Void
    ) async throws {
        let directory = LocalSpeechModelStore.modelsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(file.filename)
        let partial = partialURL(for: file.filename)

        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ModelDownloadError.alreadyInstalled(file.filename)
        }
        try checkFreeSpace(for: file, in: directory)

        var resumeFrom = partialSize(for: file.filename)
        if resumeFrom > file.sizeBytes {
            try? FileManager.default.removeItem(at: partial)
            resumeFrom = 0
        }

        if resumeFrom < file.sizeBytes {
            resumeFrom = try await fetch(
                url: model.downloadURL(for: file),
                into: partial,
                resumeFrom: resumeFrom,
                expectedSize: file.sizeBytes,
                onProgress: onProgress
            )
        }

        guard resumeFrom == file.sizeBytes else {
            throw ModelDownloadError.sizeMismatch(expected: file.sizeBytes, actual: resumeFrom)
        }

        onVerify()
        let digest = try await sha256(of: partial)
        guard digest == file.sha256 else {
            try? FileManager.default.removeItem(at: partial)
            throw ModelDownloadError.checksumMismatch(file.filename)
        }

        try FileManager.default.moveItem(at: partial, to: destination)
    }

    /// Appends the remote file to `partial` starting at `resumeFrom` and returns
    /// the resulting file size.
    private nonisolated static func fetch(
        url: URL,
        into partial: URL,
        resumeFrom: UInt64,
        expectedSize: UInt64,
        onProgress: @escaping (UInt64, UInt64, Double) -> Void
    ) async throws -> UInt64 {
        var request = URLRequest(url: url, timeoutInterval: connectTimeout)
        if resumeFrom > 0 {
            request.setValue("bytes=\(resumeFrom)-", forHTTPHeaderField: "Range")
        }

        let writer = try PartialFileWriter(
            partial: partial,
            resumeFrom: resumeFrom,
            expectedSize: expectedSize,
            onProgress: onProgress
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = stallTimeout
        configuration.timeoutIntervalForResource = 0
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return try await writer.run(request: request, configuration: configuration)
    }


    private nonisolated static func checkFreeSpace(for file: CatalogQuantFile, in directory: URL) throws {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }
        let needed = Int64(file.sizeBytes) + 256 * 1024 * 1024
        guard available >= needed else {
            throw ModelDownloadError.insufficientSpace(needed: UInt64(needed), available: UInt64(max(0, available)))
        }
    }

    private nonisolated static func sha256(of url: URL) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    var hasher = SHA256()
                    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                        hasher.update(data: chunk)
                    }
                    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                    continuation.resume(returning: digest)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// Streams one HTTP response body into a `.partial` file, appending after the
/// resume offset. A delegate is used instead of `URLSession.bytes` so body data
/// arrives in large chunks and never has to be staged in a second file.
///
/// The status code decides what happens to the bytes already on disk: a `200`
/// means the server ignored our `Range` header, so the partial is truncated to
/// zero rather than having a whole file appended to it, and a `206` that starts
/// at the wrong offset makes the partial unusable and fails the transfer.
private final class PartialFileWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let partial: URL
    private let resumeFrom: UInt64
    private let expectedSize: UInt64
    private let onProgress: (UInt64, UInt64, Double) -> Void

    private var handle: FileHandle?
    private var received: UInt64 = 0
    private var startTime = Date()
    private var lastReport = Date.distantPast
    private var failure: Error?
    private var continuation: CheckedContinuation<UInt64, Error>?

    init(
        partial: URL,
        resumeFrom: UInt64,
        expectedSize: UInt64,
        onProgress: @escaping (UInt64, UInt64, Double) -> Void
    ) throws {
        self.partial = partial
        self.resumeFrom = resumeFrom
        self.expectedSize = expectedSize
        self.onProgress = onProgress
        super.init()
    }

    func run(request: URLRequest, configuration: URLSessionConfiguration) async throws -> UInt64 {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.startTime = Date()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            fail(ModelDownloadError.transport("The server sent a response Textream cannot read."))
            completionHandler(.cancel)
            return
        }

        var offset = resumeFrom
        switch http.statusCode {
        case 200:
            offset = 0
        case 206:
            let start = http.value(forHTTPHeaderField: "Content-Range")
                .flatMap(Self.contentRangeStart) ?? resumeFrom
            guard start == resumeFrom else {
                try? FileManager.default.removeItem(at: partial)
                fail(ModelDownloadError.transport("The server resumed at the wrong offset. Retry the download."))
                completionHandler(.cancel)
                return
            }
        case 401, 403:
            fail(ModelDownloadError.transport("Hugging Face refused access to this model file."))
            completionHandler(.cancel)
            return
        case 404:
            fail(ModelDownloadError.transport("This model file is no longer on Hugging Face."))
            completionHandler(.cancel)
            return
        case 429:
            fail(ModelDownloadError.transport("Hugging Face is rate limiting downloads. Try again in a few minutes."))
            completionHandler(.cancel)
            return
        default:
            fail(ModelDownloadError.transport("Hugging Face returned HTTP \(http.statusCode)."))
            completionHandler(.cancel)
            return
        }

        do {
            if !FileManager.default.fileExists(atPath: partial.path) {
                FileManager.default.createFile(atPath: partial.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: partial)
            try handle.truncate(atOffset: offset)
            try handle.seekToEnd()
            self.handle = handle
            self.received = offset
            completionHandler(.allow)
        } catch {
            fail(error)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handle, failure == nil else { return }
        // Never trust a server that sends more than the catalog size.
        let remaining = expectedSize > received ? Int(expectedSize - received) : 0
        guard remaining > 0 else {
            dataTask.cancel()
            return
        }
        let slice = data.count > remaining ? data.prefix(remaining) : data
        do {
            try handle.write(contentsOf: slice)
            received += UInt64(slice.count)
        } catch {
            fail(error)
            dataTask.cancel()
            return
        }

        let now = Date()
        if now.timeIntervalSince(lastReport) > 0.2 || received >= expectedSize {
            lastReport = now
            let elapsed = max(0.001, now.timeIntervalSince(startTime))
            let speed = Double(received - min(received, resumeFrom)) / elapsed
            onProgress(received, expectedSize, speed)
        }
        if received >= expectedSize { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil

        guard let continuation else { return }
        self.continuation = nil

        if let failure {
            continuation.resume(throwing: failure)
            return
        }
        // A cancel we issued after the last needed byte is a success, not a failure.
        if let error, !(received >= expectedSize && (error as NSError).code == NSURLErrorCancelled) {
            if (error as NSError).code == NSURLErrorCancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                continuation.resume(throwing: error)
            }
            return
        }
        continuation.resume(returning: received)
    }

    private func fail(_ error: Error) {
        if failure == nil { failure = error }
    }

    private static func contentRangeStart(_ value: String) -> UInt64? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.split(separator: " ").last else { return nil }
        return UInt64(range.split(separator: "-").first.map(String.init) ?? "")
    }
}


enum ModelDownloadError: LocalizedError {
    case alreadyInstalled(String)
    case checksumMismatch(String)
    case sizeMismatch(expected: UInt64, actual: UInt64)
    case insufficientSpace(needed: UInt64, available: UInt64)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .alreadyInstalled(let name):
            return "\"\(name)\" is already installed."
        case .checksumMismatch(let name):
            return "\"\(name)\" arrived corrupt and was deleted. Retry the download."
        case .sizeMismatch(let expected, let actual):
            return "The download stopped early: got \(actual) of \(expected) bytes. Retry to resume."
        case .insufficientSpace(let needed, let available):
            return "Not enough disk space: \(needed / 1_048_576) MB needed, \(available / 1_048_576) MB free."
        case .transport(let message):
            return message
        }
    }
}
