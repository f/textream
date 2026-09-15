//
//  ModelRepositoryStore.swift
//  Textream
//
//  User-added Hugging Face repositories, on top of the bundled catalog. Other
//  people publish GGUF conversions too, so the bundled list is a starting set
//  rather than the limit.
//
//  A repo is resolved once, when it is added: the Hub API supplies the commit
//  sha, the per-file sizes and the LFS SHA-256 for every candidate file, which
//  is exactly the shape the bundled catalog already has. Pinning the sha at that
//  moment means an added repo downloads with the same guarantee as a bundled
//  one — the bytes are provably the ones that were inspected.
//

import Foundation

@Observable
@MainActor
final class ModelRepositoryStore {
    static let shared = ModelRepositoryStore()

    /// Resolved user repos, newest last. Same shape as the bundled catalog, so
    /// the rest of the app treats them identically.
    private(set) var models: [CatalogModel] = []

    private static var fileURL: URL {
        LocalSpeechModelStore.modelsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("CustomRepositories.json")
    }

    private init() {
        load()
    }

    func contains(repoID: String) -> Bool {
        models.contains { $0.repoID.caseInsensitiveCompare(repoID) == .orderedSame }
            || SpeechModelCatalog.models.contains { $0.repoID.caseInsensitiveCompare(repoID) == .orderedSame }
    }

    /// Resolves `repoID` against the Hub and adds it. Throws rather than adding
    /// a partial entry, so a repo in the list is always one that can be
    /// downloaded and verified.
    func add(repoID: String) async throws -> CatalogModel {
        let trimmed = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = Self.normalizeRepoID(trimmed)
        guard !normalized.isEmpty, normalized.split(separator: "/").count == 2 else {
            throw ModelRepositoryError.malformedID(trimmed)
        }
        guard !contains(repoID: normalized) else {
            throw ModelRepositoryError.alreadyAdded(normalized)
        }

        let model = try await HuggingFaceRepositoryResolver.resolve(repoID: normalized)
        models.append(model)
        save()
        return model
    }

    func remove(_ model: CatalogModel) {
        models.removeAll { $0.repoID == model.repoID }
        save()
    }

    /// Accepts a full `huggingface.co/owner/name` URL as well as a bare id.
    static func normalizeRepoID(_ input: String) -> String {
        var value = input
        for prefix in ["https://huggingface.co/", "http://huggingface.co/", "huggingface.co/"] {
            if value.lowercased().hasPrefix(prefix) {
                value = String(value.dropFirst(prefix.count))
                break
            }
        }
        if let slash = value.range(of: "/tree/") ?? value.range(of: "/blob/") {
            value = String(value[value.startIndex..<slash.lowerBound])
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    // MARK: - Persistence

    private struct Root: Codable {
        let models: [CatalogModel]
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        models = (try? JSONDecoder().decode(Root.self, from: data))?.models ?? []
    }

    private func save() {
        let url = Self.fileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Root(models: models)).write(to: url, options: .atomic)
        } catch {
            NSLog("Textream: could not save custom model repositories: \(error.localizedDescription)")
        }
    }
}

/// Turns a Hugging Face repo id into a [`CatalogModel`] by reading the Hub API
/// and probing each candidate file's magic bytes.
enum HuggingFaceRepositoryResolver {
    /// Files the transcribe.cpp engine can load. `.bin` is ambiguous on the Hub
    /// (`pytorch_model.bin` is a zip archive), so extension alone is not enough
    /// and the first four bytes decide.
    private static let ggufMagic = Data([0x47, 0x47, 0x55, 0x46])          // "GGUF"
    private static let ggmlMagic = Data([0x6C, 0x6D, 0x67, 0x67])          // legacy ggml

    private struct APIResponse: Decodable {
        struct Sibling: Decodable {
            struct LFS: Decodable {
                let sha256: String?
                let size: UInt64?
            }
            let rfilename: String
            let size: UInt64?
            let lfs: LFS?
        }
        struct CardData: Decodable {
            let license: String?
            let baseModel: BaseModel?

            enum CodingKeys: String, CodingKey {
                case license
                case baseModel = "base_model"
            }

            /// The Hub allows a single string or a list here.
            enum BaseModel: Decodable {
                case one(String)
                case many([String])

                var first: String? {
                    switch self {
                    case .one(let value): return value
                    case .many(let values): return values.first
                    }
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let single = try? container.decode(String.self) {
                        self = .one(single)
                    } else {
                        self = .many(try container.decode([String].self))
                    }
                }
            }
        }
        struct GGUF: Decodable {
            let architecture: String?
        }
        let id: String
        let sha: String?
        let gated: GatedFlag?
        let `private`: Bool?
        let siblings: [Sibling]?
        let cardData: CardData?
        let gguf: GGUF?

        /// `gated` is `false` or a string such as `"auto"` / `"manual"`.
        enum GatedFlag: Decodable {
            case no
            case yes(String)

            var isGated: Bool {
                if case .yes = self { return true }
                return false
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let flag = try? container.decode(Bool.self) {
                    self = flag ? .yes("gated") : .no
                } else {
                    self = .yes(try container.decode(String.self))
                }
            }
        }
    }

    static func resolve(repoID: String) async throws -> CatalogModel {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repoID)?blobs=true") else {
            throw ModelRepositoryError.malformedID(repoID)
        }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ModelRepositoryError.lookupFailed("The Hugging Face API sent an unreadable response.")
        }
        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            // The Hub answers 401 both for a gated repo and for one that does
            // not exist, so neither reading is safe to state on its own.
            throw ModelRepositoryError.notReachable(repoID)
        case 404:
            throw ModelRepositoryError.notFound(repoID)
        case 429:
            throw ModelRepositoryError.lookupFailed("Hugging Face is rate limiting requests. Try again in a few minutes.")
        default:
            throw ModelRepositoryError.lookupFailed("Hugging Face returned HTTP \(http.statusCode).")
        }

        let payload = try JSONDecoder().decode(APIResponse.self, from: data)
        if payload.gated?.isGated == true || payload.private == true {
            throw ModelRepositoryError.notPublic(repoID)
        }
        guard let revision = payload.sha, !revision.isEmpty else {
            throw ModelRepositoryError.lookupFailed("Hugging Face did not report a commit for \(repoID).")
        }

        let candidates = (payload.siblings ?? []).filter {
            let name = $0.rfilename.lowercased()
            return name.hasSuffix(".gguf") || name.hasSuffix(".bin")
        }
        guard !candidates.isEmpty else {
            throw ModelRepositoryError.noUsableFiles(repoID)
        }

        var files: [CatalogQuantFile] = []
        for candidate in candidates {
            guard let sha256 = candidate.lfs?.sha256 else { continue }
            let size = candidate.lfs?.size ?? candidate.size ?? 0
            guard size > 0 else { continue }
            guard try await isEngineReadable(repoID: repoID, revision: revision, filename: candidate.rfilename) else { continue }
            files.append(CatalogQuantFile(
                filename: candidate.rfilename,
                quant: "",
                sizeBytes: size,
                sha256: sha256
            ))
        }
        guard !files.isEmpty else {
            throw ModelRepositoryError.noUsableFiles(repoID)
        }
        files.sort { $0.sizeBytes < $1.sizeBytes }
        files = Self.labelled(files)

        let name = repoID.split(separator: "/").last.map(String.init) ?? repoID
        return CatalogModel(
            repoID: payload.id,
            revision: revision,
            name: displayName(from: name),
            description: "Added from Hugging Face.",
            architecture: payload.gguf?.architecture,
            parameters: nil,
            baseModel: payload.cardData?.baseModel?.first,
            license: payload.cardData?.license,
            languages: [],
            // Real capabilities come from the engine when the model loads, so
            // nothing is claimed here that has not been observed.
            capabilities: CatalogCapabilities(streaming: false, translate: false, langDetect: false),
            speedScore: nil,
            accuracyScore: nil,
            defaultQuant: files.first?.quant,
            files: files,
            recommended: false,
            userAdded: true
        )
    }

    /// Reads the first four bytes of a file to tell a real GGUF/GGML model from
    /// something that merely ends in `.bin`.
    private static func isEngineReadable(repoID: String, revision: String, filename: String) async throws -> Bool {
        let encoded = filename
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        guard let url = URL(string: "https://huggingface.co/\(repoID)/resolve/\(revision)/\(encoded)") else {
            return false
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("bytes=0-3", forHTTPHeaderField: "Range")
        guard let (data, _) = try? await URLSession.shared.data(for: request), data.count >= 4 else {
            return false
        }
        let head = data.prefix(4)
        return head == ggufMagic || head == ggmlMagic
    }

    /// Fills in each file's picker label. A repo holding one model in several
    /// quants (`whisper-tiny-Q8_0.gguf`) reads best as the quant alone, but a
    /// repo holding several distinct models (`ggml-tiny.en-q5_1.bin` beside
    /// `ggml-base-q8_0.bin`) would collapse into repeated labels, so the full
    /// stem is used unless every quant suffix in the repo is distinct.
    private static func labelled(_ files: [CatalogQuantFile]) -> [CatalogQuantFile] {
        let suffixes = files.map { quantSuffix(of: $0.filename) }
        let useSuffix = !suffixes.contains(nil) && Set(suffixes.compactMap { $0 }).count == files.count

        return zip(files, suffixes).map { file, suffix in
            CatalogQuantFile(
                filename: file.filename,
                quant: useSuffix ? suffix! : (file.filename as NSString).deletingPathExtension,
                sizeBytes: file.sizeBytes,
                sha256: file.sha256
            )
        }
    }

    /// The quant part of a conversion's filename (`…-Q8_0.gguf` → `Q8_0`), or
    /// nil when the name does not end in one.
    private static func quantSuffix(of filename: String) -> String? {
        let stem = (filename as NSString).deletingPathExtension
        guard let dash = stem.lastIndex(of: "-") else { return nil }
        let suffix = String(stem[stem.index(after: dash)...])
        guard suffix.count <= 8,
              let first = suffix.first,
              first == "Q" || first == "q" || first == "F" || first == "f" else { return nil }
        return suffix.uppercased()
    }


    private static func displayName(from slug: String) -> String {
        slug
            .replacingOccurrences(of: "-gguf", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

enum ModelRepositoryError: LocalizedError {
    case malformedID(String)
    case alreadyAdded(String)
    case notFound(String)
    case notPublic(String)
    case notReachable(String)
    case noUsableFiles(String)
    case lookupFailed(String)

    var errorDescription: String? {
        switch self {
        case .malformedID(let value):
            return "\"\(value)\" is not a repo id. Use owner/name, for example handy-computer/whisper-tiny-gguf."
        case .alreadyAdded(let value):
            return "\(value) is already in the list."
        case .notFound(let value):
            return "\(value) does not exist on Hugging Face."
        case .notPublic(let value):
            return "\(value) is private or gated, so Textream cannot download from it."
        case .notReachable(let value):
            return "\(value) could not be read. Check the spelling, and note that private and gated repos are not supported."
        case .noUsableFiles(let value):
            return "\(value) has no GGUF model files Textream can run."
        case .lookupFailed(let message):
            return message
        }
    }
}
