//
//  SpeechModelCatalog.swift
//  Textream
//
//  The bundled catalog of downloadable Whisper-family speech models. The JSON
//  is compiled into the app, so the model list is complete without network
//  access. Every entry is a file inside a Hugging Face repo pinned to an
//  immutable revision, which is the only download source: there is no mirror
//  and no bundled model.
//

import Foundation

struct CatalogQuantFile: Codable, Hashable, Identifiable {
    let filename: String
    let quant: String
    let sizeBytes: UInt64
    let sha256: String

    enum CodingKeys: String, CodingKey {
        case filename, quant, sha256
        case sizeBytes = "size_bytes"
    }

    var id: String { filename }
    var sizeMB: UInt64 { sizeBytes / (1024 * 1024) }
}

struct CatalogCapabilities: Codable, Hashable {
    let streaming: Bool
    let translate: Bool
    let langDetect: Bool

    enum CodingKeys: String, CodingKey {
        case streaming, translate
        case langDetect = "lang_detect"
    }
}

struct CatalogModel: Codable, Hashable, Identifiable {
    let repoID: String
    let revision: String
    let name: String
    let description: String
    let architecture: String?
    let parameters: String?
    /// The upstream model these weights were converted from. Shown in the model
    /// card so the original authors are credited, not just the GGUF publisher.
    let baseModel: String?
    let license: String?
    let languages: [String]
    let capabilities: CatalogCapabilities
    let speedScore: Double?
    let accuracyScore: Double?
    let defaultQuant: String?
    let files: [CatalogQuantFile]
    let recommended: Bool

    enum CodingKeys: String, CodingKey {
        case repoID = "repo_id"
        case revision, name, description, architecture, parameters, license, languages, capabilities, files, recommended
        case baseModel = "base_model"
        case speedScore = "speed_score"
        case accuracyScore = "accuracy_score"
        case defaultQuant = "default_quant"
    }

    var id: String { repoID }

    /// Catalog scores are 0–100; the settings bars use 0.0–1.0.
    var normalizedSpeed: Double { (speedScore ?? 0) / 100 }
    var normalizedAccuracy: Double { (accuracyScore ?? 0) / 100 }

    /// The Hugging Face page for the repo these weights come from.
    var repoURL: URL {
        URL(string: "https://huggingface.co/\(repoID)")!
    }

    /// The Hugging Face page for the upstream model, when the catalog names one.
    var baseModelURL: URL? {
        baseModel.flatMap { URL(string: "https://huggingface.co/\($0)") }
    }

    /// Source and license credit for the model card. The license is part of the
    /// terms for several of these models (the NVIDIA ones are CC-BY-4.0, which
    /// requires attribution), so it is shown rather than only recorded.
    var attribution: String {
        var parts = [repoID]
        if let baseModel { parts.append("from \(baseModel)") }
        if let license { parts.append(license.uppercased()) }
        return parts.joined(separator: " · ")
    }

    var defaultFile: CatalogQuantFile {
        files.first { $0.quant == defaultQuant } ?? files[0]
    }

    func file(quant: String) -> CatalogQuantFile? {
        files.first { $0.quant == quant }
    }

    func file(named filename: String) -> CatalogQuantFile? {
        files.first { $0.filename == filename }
    }

    /// The immutable Hugging Face resolve URL for one quant of this model.
    func downloadURL(for file: CatalogQuantFile) -> URL {
        URL(string: "https://huggingface.co/\(repoID)/resolve/\(revision)/\(file.filename)")!
    }

    /// `en, tr, de +96` style summary for the settings list.
    var languageSummary: String {
        let head = languages.prefix(3).joined(separator: ", ")
        let rest = languages.count - min(3, languages.count)
        return rest > 0 ? "\(head) +\(rest)" : head
    }
}

enum SpeechModelCatalog {
    private struct Root: Codable {
        let models: [CatalogModel]
    }

    static let models: [CatalogModel] = {
        guard let url = Bundle.main.url(forResource: "SpeechModelCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            assertionFailure("SpeechModelCatalog.json is missing from the app bundle")
            return []
        }
        do {
            return try JSONDecoder().decode(Root.self, from: data).models
        } catch {
            assertionFailure("SpeechModelCatalog.json does not match the catalog schema: \(error)")
            return []
        }
    }()

    /// The catalog entry that owns `filename`, for matching files already on disk.
    static func model(containing filename: String) -> (model: CatalogModel, file: CatalogQuantFile)? {
        for model in models {
            if let file = model.file(named: filename) { return (model, file) }
        }
        return nil
    }
}
