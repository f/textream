//
//  LocalSpeechModels.swift
//  Textream
//
//  Custom local (Whisper-family) speech models: on-disk discovery, import,
//  and deletion. Mirrors Handy's custom-model discovery: any `.bin` (legacy
//  GGML) or `.gguf` file dropped into the models directory is offered as a
//  selectable model, with its display name derived from the filename.
//

import Foundation
import AppKit

struct LocalSpeechModel: Identifiable, Hashable {
    let filename: String
    let url: URL
    let sizeMB: UInt64

    var id: String { filename }
    var displayName: String { LocalSpeechModel.displayName(for: filename) }

    static func displayName(for filename: String) -> String {
        let stem = (filename as NSString).deletingPathExtension
        return stem
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

enum LocalModelError: LocalizedError {
    case unsupportedFileType
    case alreadyExists(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType:
            return "Only Whisper-family .bin and .gguf models can be imported."
        case .alreadyExists(let name):
            return "A model named \"\(name)\" already exists. Delete it first to replace it."
        case .notFound(let name):
            return "The model \"\(name)\" was not found in the models folder."
        }
    }
}

@Observable
final class LocalSpeechModelStore {
    static let shared = LocalSpeechModelStore()

    private(set) var models: [LocalSpeechModel] = []
    var lastError: String?

    static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Textream/Models", isDirectory: true)
    }

    private init() {
        refresh()
    }

    /// Re-scan the models directory for `.bin` / `.gguf` files.
    func refresh() {
        let fileManager = FileManager.default
        let directory = Self.modelsDirectory
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []

        models = entries.compactMap { url -> LocalSpeechModel? in
            let ext = url.pathExtension.lowercased()
            guard ext == "bin" || ext == "gguf" else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { return nil }
            let size = UInt64(values?.fileSize ?? 0)
            return LocalSpeechModel(
                filename: url.lastPathComponent,
                url: url,
                sizeMB: size / (1024 * 1024)
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func model(named filename: String) -> LocalSpeechModel? {
        models.first { $0.filename == filename }
    }

    func importModel(from sourceURL: URL) async throws -> LocalSpeechModel {
        let ext = sourceURL.pathExtension.lowercased()
        guard ext == "bin" || ext == "gguf" else { throw LocalModelError.unsupportedFileType }

        let directory = Self.modelsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(sourceURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw LocalModelError.alreadyExists(sourceURL.lastPathComponent)
        }

        try await Self.copyInBackground(from: sourceURL, to: destination)
        refresh()

        guard let model = model(named: sourceURL.lastPathComponent) else {
            throw LocalModelError.notFound(sourceURL.lastPathComponent)
        }
        return model
    }

    func delete(_ model: LocalSpeechModel) throws {
        try FileManager.default.removeItem(at: model.url)
        refresh()
    }

    func revealInFinder() {
        let directory = Self.modelsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    nonisolated private static func copyInBackground(from sourceURL: URL, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let didAccess = sourceURL.startAccessingSecurityScopedResource()
                    defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
                    try FileManager.default.copyItem(at: sourceURL, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
