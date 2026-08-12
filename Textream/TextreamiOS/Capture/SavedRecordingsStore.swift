@preconcurrency import Photos
@preconcurrency import AVFoundation
import Observation
import UIKit

struct SavedRecording: Identifiable {
    let assetIdentifier: String
    let thumbnail: UIImage
    let createdAt: Date
    let duration: TimeInterval

    var id: String { assetIdentifier }
}

final class SavedRecordingVideoAsset: @unchecked Sendable {
    nonisolated(unsafe) let asset: AVAsset

    nonisolated init(_ asset: AVAsset) {
        self.asset = asset
    }
}

private final class ThumbnailContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var didResume = false

    nonisolated func claim() -> Bool {
        lock.withLock {
            guard !didResume else { return false }
            didResume = true
            return true
        }
    }
}

enum SavedRecordingsAuthorizationState: Equatable {
    case notDetermined
    case ready
    case limited
    case denied
}

enum SavedRecordingsDeleteError: LocalizedError {
    case photosAccessDenied
    case recordingsUnavailable
    case deletionFailed(String)

    var errorDescription: String? {
        switch self {
        case .photosAccessDenied:
            "Allow full Photos access to delete Textream recordings."
        case .recordingsUnavailable:
            "The selected recordings are no longer available in Photos."
        case .deletionFailed(let detail):
            "The recordings could not be deleted: \(detail)"
        }
    }
}

enum SavedRecordingsEditError: LocalizedError {
    case photosAccessDenied
    case recordingUnavailable
    case exportUnavailable
    case nativeEditorUnavailable
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .photosAccessDenied:
            "Allow Photos access to save an edited copy of this recording."
        case .recordingUnavailable:
            "This recording is no longer available in Photos."
        case .exportUnavailable:
            "This recording could not be prepared for editing."
        case .nativeEditorUnavailable:
            "This video cannot be edited with the Photos editor."
        case .saveFailed(let detail):
            "The edited recording could not be saved: \(detail)"
        }
    }
}

struct SavedRecordingEditWorkspace: Equatable, Sendable {
    let directoryURL: URL
    let sourceURL: URL

    nonisolated static func make(
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> Self {
        let directory = temporaryDirectory
            .appendingPathComponent("TextreamVideoEdits", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return Self(
            directoryURL: directory,
            sourceURL: directory.appendingPathComponent("source.mov")
        )
    }
}

private final class PhotoAssetIdentifierBox: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var identifier: String?

    nonisolated func store(_ identifier: String?) {
        lock.withLock { self.identifier = identifier }
    }

    nonisolated func load() -> String? {
        lock.withLock { identifier }
    }
}

@MainActor
private final class PhotosSaveBackgroundActivity {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init() {
        identifier = UIApplication.shared.beginBackgroundTask(
            withName: "Save Textream Edit"
        ) { [weak self] in
            Task { @MainActor in self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        let current = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(current)
    }
}

@Observable
@MainActor
final class SavedRecordingsStore {
    private enum Constants {
        static let defaultsKey = "ios.savedRecordingAssetIdentifiers"
        static let maximumRememberedRecordings = 250
    }

    private(set) var recordings: [SavedRecording] = []
    private(set) var authorizationState: SavedRecordingsAuthorizationState = .notDetermined
    private(set) var isLoading = false
    private(set) var isDeleting = false
    private(set) var isEditing = false
    private(set) var recordedAssetIdentifiers: [String]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let defaultsKey: String
    @ObservationIgnored private let loadsFromPhotos: Bool

    init(
        defaults: UserDefaults = .standard,
        defaultsKey: String = Constants.defaultsKey
    ) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        loadsFromPhotos = true
        recordedAssetIdentifiers = Self.normalizedIdentifiers(
            defaults.stringArray(forKey: defaultsKey) ?? [],
            limit: Constants.maximumRememberedRecordings
        )
    }

    #if DEBUG
    init(previewRecordings: [SavedRecording]) {
        defaults = .standard
        defaultsKey = Constants.defaultsKey
        loadsFromPhotos = false
        recordings = previewRecordings
        recordedAssetIdentifiers = previewRecordings.map(\.assetIdentifier)
        authorizationState = .ready
    }
    #endif

    var hasRememberedRecordings: Bool { !recordedAssetIdentifiers.isEmpty }

    func remember(assetIdentifier: String) {
        guard !assetIdentifier.isEmpty else { return }
        recordedAssetIdentifiers = Self.normalizedIdentifiers(
            [assetIdentifier] + recordedAssetIdentifiers,
            limit: Constants.maximumRememberedRecordings
        )
        defaults.set(recordedAssetIdentifiers, forKey: defaultsKey)
    }

    func loadRecordings() async {
        guard loadsFromPhotos, !isLoading, !isDeleting, !isEditing else { return }
        isLoading = true
        defer { isLoading = false }

        let status = await Self.requestReadAuthorization()
        guard !Task.isCancelled else { return }
        switch status {
        case .authorized:
            authorizationState = .ready
        case .limited:
            authorizationState = .limited
        case .denied, .restricted:
            authorizationState = .denied
            recordings = []
            return
        case .notDetermined:
            authorizationState = .notDetermined
            recordings = []
            return
        @unknown default:
            authorizationState = .denied
            recordings = []
            return
        }

        let identifiers = recordedAssetIdentifiers
        guard !identifiers.isEmpty else {
            recordings = []
            return
        }

        let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assetsByIdentifier: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .video else { return }
            assetsByIdentifier[asset.localIdentifier] = asset
        }

        var loaded: [SavedRecording] = []
        loaded.reserveCapacity(assetsByIdentifier.count)
        for identifier in identifiers {
            guard !Task.isCancelled,
                  let asset = assetsByIdentifier[identifier],
                  let thumbnail = await Self.requestThumbnail(for: asset) else { continue }
            loaded.append(
                SavedRecording(
                    assetIdentifier: identifier,
                    thumbnail: thumbnail,
                    createdAt: asset.creationDate ?? .distantPast,
                    duration: asset.duration
                )
            )
        }
        recordings = loaded
    }

    func refreshIfAuthorized() async {
        guard loadsFromPhotos, !isDeleting, !isEditing else { return }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        await loadRecordings()
    }

    func videoAsset(for recording: SavedRecording) async -> SavedRecordingVideoAsset? {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [recording.assetIdentifier], options: nil)
        guard let asset = result.firstObject, asset.mediaType == .video else { return nil }
        return await Self.requestVideoAsset(for: asset)
    }

    func beginEditing(_ recording: SavedRecording) async throws -> URL {
        guard !isEditing, !isDeleting, !isLoading else {
            throw SavedRecordingsEditError.exportUnavailable
        }
        isEditing = true
        var workspace: SavedRecordingEditWorkspace?
        do {
            let result = PHAsset.fetchAssets(
                withLocalIdentifiers: [recording.assetIdentifier],
                options: nil
            )
            guard let photoAsset = result.firstObject, photoAsset.mediaType == .video else {
                throw SavedRecordingsEditError.recordingUnavailable
            }
            guard let videoAsset = await Self.requestVideoAsset(for: photoAsset) else {
                throw SavedRecordingsEditError.recordingUnavailable
            }

            let preparedWorkspace = try SavedRecordingEditWorkspace.make()
            workspace = preparedWorkspace
            let destination = try await Self.exportEditableVideo(
                videoAsset.asset,
                into: preparedWorkspace
            )
            try Task.checkCancellation()
            return destination
        } catch {
            Self.removeTemporaryVideo(at: workspace?.directoryURL)
            isEditing = false
            throw error
        }
    }

    func saveEditedRecording(at videoURL: URL) async throws -> SavedRecording {
        guard isEditing, !isDeleting, !isLoading else {
            throw SavedRecordingsEditError.saveFailed("No recording is being edited.")
        }
        defer { finishEditing() }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw SavedRecordingsEditError.photosAccessDenied
        }

        // Build the player/gallery metadata before the Photos transaction. A
        // successful write must remain a success even if Photos needs time to
        // surface the newly-created PHAsset in a subsequent fetch.
        let metadata = try await Self.editedVideoMetadata(at: videoURL)
        let backgroundActivity = PhotosSaveBackgroundActivity()
        defer { backgroundActivity.end() }
        let identifier = try await Self.createPhotoAsset(fromVideoAt: videoURL)
        remember(assetIdentifier: identifier)

        let recording = SavedRecording(
            assetIdentifier: identifier,
            thumbnail: metadata.thumbnail,
            createdAt: .now,
            duration: metadata.duration
        )
        cacheNewest(recording)
        return recording
    }

    func finishEditing() {
        isEditing = false
    }

    func cacheNewest(_ recording: SavedRecording) {
        recordings.removeAll { $0.assetIdentifier == recording.assetIdentifier }
        recordings.insert(recording, at: 0)
    }

    func deleteRecordings(with identifiers: Set<String>) async throws -> Set<String> {
        let remembered = identifiers.intersection(recordedAssetIdentifiers)
        guard !remembered.isEmpty, !isDeleting, !isLoading, !isEditing else { return [] }
        isDeleting = true
        defer { isDeleting = false }

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw SavedRecordingsDeleteError.photosAccessDenied
        }
        let deletedIdentifiers = try await Self.deletePhotoAssets(
            with: Array(remembered),
            authorizationStatus: status
        )
        let deleted = Set(deletedIdentifiers)
        forget(assetIdentifiers: deleted)
        return deleted
    }

    func forget(assetIdentifiers: Set<String>) {
        guard !assetIdentifiers.isEmpty else { return }
        recordedAssetIdentifiers.removeAll { assetIdentifiers.contains($0) }
        recordings.removeAll { assetIdentifiers.contains($0.assetIdentifier) }
        defaults.set(recordedAssetIdentifiers, forKey: defaultsKey)
    }

    static func normalizedIdentifiers(_ identifiers: [String], limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var seen: Set<String> = []
        return identifiers.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(limit).map { $0 }
    }

    nonisolated static func removeTemporaryVideo(at url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func exportEditableVideo(
        _ asset: AVAsset,
        into workspace: SavedRecordingEditWorkspace
    ) async throws -> URL {
        var lastError: Error?
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality] {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
                continue
            }
            let fileType: AVFileType
            if session.supportedFileTypes.contains(.mov) {
                fileType = .mov
            } else if session.supportedFileTypes.contains(.mp4) {
                fileType = .mp4
            } else {
                continue
            }
            let destination = fileType == .mov
                ? workspace.sourceURL
                : workspace.sourceURL.deletingPathExtension().appendingPathExtension("mp4")
            removeTemporaryVideo(at: destination)
            do {
                try await session.export(to: destination, as: fileType)
                return destination
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                removeTemporaryVideo(at: destination)
            }
        }
        throw lastError ?? SavedRecordingsEditError.exportUnavailable
    }

    private static func editedVideoMetadata(
        at url: URL
    ) async throws -> (thumbnail: UIImage, duration: TimeInterval) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        let generated = try await generator.image(at: .zero)
        return (
            UIImage(cgImage: generated.image),
            max(0, duration.seconds.isFinite ? duration.seconds : 0)
        )
    }

    nonisolated private static func requestReadAuthorization() async -> PHAuthorizationStatus {
        let existing = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard existing == .notDetermined else { return existing }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    nonisolated private static func requestThumbnail(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let gate = ThumbnailContinuationGate()
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 720, height: 720),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let isDegraded = info?[PHImageResultIsDegradedKey] as? Bool == true
                guard !isDegraded, gate.claim() else { return }
                let cancelled = info?[PHImageCancelledKey] as? Bool == true
                let failed = info?[PHImageErrorKey] != nil
                continuation.resume(returning: cancelled || failed ? nil : image)
            }
        }
    }

    nonisolated private static func requestVideoAsset(for asset: PHAsset) async -> SavedRecordingVideoAsset? {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .automatic
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { videoAsset, _, _ in
                continuation.resume(returning: videoAsset.map(SavedRecordingVideoAsset.init))
            }
        }
    }

    /// Saves the editor's temporary output as a separate Photos asset. The
    /// original recording is intentionally left unchanged.
    nonisolated private static func createPhotoAsset(fromVideoAt url: URL) async throws -> String {
        let identifierBox = PhotoAssetIdentifierBox()
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(
                    atFileURL: url
                )
                identifierBox.store(request?.placeholderForCreatedAsset?.localIdentifier)
            }, completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(
                        throwing: SavedRecordingsEditError.saveFailed(
                            "Photos did not create the edited recording."
                        )
                    )
                }
            })
        }
        guard let identifier = identifierBox.load() else {
            throw SavedRecordingsEditError.saveFailed(
                "Photos did not return the new recording identifier."
            )
        }
        return identifier
    }


    /// PhotoKit runs its completion on an arbitrary serial queue. Keeping the
    /// entire bridge nonisolated avoids inheriting the app's MainActor default.
    nonisolated private static func deletePhotoAssets(
        with identifiers: [String],
        authorizationStatus: PHAuthorizationStatus
    ) async throws -> [String] {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var deletableAssets: [PHAsset] = []
        var foundIdentifiers: Set<String> = []
        result.enumerateObjects { asset, _, _ in
            foundIdentifiers.insert(asset.localIdentifier)
            guard asset.mediaType == .video, asset.canPerform(.delete) else { return }
            deletableAssets.append(asset)
        }
        guard deletableAssets.count == foundIdentifiers.count else {
            throw SavedRecordingsDeleteError.recordingsUnavailable
        }

        let missingIdentifiers = Set(identifiers).subtracting(foundIdentifiers)
        if authorizationStatus == .limited, !missingIdentifiers.isEmpty {
            throw SavedRecordingsDeleteError.recordingsUnavailable
        }

        guard !deletableAssets.isEmpty else { return Array(missingIdentifiers) }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(deletableAssets as NSArray)
            }, completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(
                            throwing: SavedRecordingsDeleteError.deletionFailed(
                                "Photos did not delete the recordings."
                            )
                        )
                    }
                }
            })
        }
        return identifiers
    }
}
