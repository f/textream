//
//  LocalModelSettingsSection.swift
//  Textream
//
//  Settings controls for the local speech engine. The section
//  itself stays compact — status, installed-model picker, and a button that
//  opens the model manager sheet where downloading happens.
//
//  Hugging Face is the only download source. When a download fails, the failure
//  is shown and the model stays uninstalled: nothing else is substituted.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LocalModelSettingsSection: View {
    @Bindable var settings: NotchSettings
    @State private var store = LocalSpeechModelStore.shared
    @State private var downloads = ModelDownloadManager.shared
    @State private var showModelManager = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Local Model")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Button("Manage Models…") { showModelManager = true }
                    .controlSize(.small)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(failureMessage == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.models.isEmpty {
                Text("No models installed. Open Manage Models to download one from Hugging Face.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Picker("", selection: $settings.localModelFilename) {
                    Text("Select a model…").tag("")
                    ForEach(store.models) { model in
                        Text("\(model.displayName) — \(model.sizeMB) MB").tag(model.filename)
                    }
                }
                .labelsHidden()
            }

            Text("Models marked Live stream words as you speak. Other models update the transcript in batches.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .onAppear {
            store.refresh()
            ensureSelection()
        }
        .sheet(isPresented: $showModelManager) {
            ModelManagerSheet(settings: settings)
        }
    }

    private var activeDownloadCount: Int {
        downloads.states.values.filter(\.isActive).count
    }

    /// The first failure still on record, so a download that failed while the
    /// manager sheet was closed is not silently swallowed.
    private var failureMessage: String? {
        downloads.states
            .sorted { $0.key < $1.key }
            .compactMap { if case .failed(let message) = $0.value { return message } else { return nil } }
            .first
    }

    private var statusColor: Color {
        if activeDownloadCount > 0 { return .accentColor }
        if failureMessage != nil { return .red }
        if store.model(named: settings.localModelFilename) != nil { return .green }
        return .secondary
    }

    private var statusText: String {
        if activeDownloadCount > 0 {
            let overall = downloads.overallProgress
            return activeDownloadCount == 1
                ? "Downloading \(Int(overall * 100))%"
                : "Downloading \(activeDownloadCount) models — \(Int(overall * 100))%"
        }
        if let failureMessage { return failureMessage }
        if let installed = store.model(named: settings.localModelFilename) {
            return "\(installed.displayName) ready — \(installed.sizeMB) MB"
        }
        return "No model selected."
    }

    private func ensureSelection() {
        guard !store.models.isEmpty else { return }
        if settings.localModelFilename.isEmpty || store.model(named: settings.localModelFilename) == nil {
            settings.localModelFilename = store.models[0].filename
        }
    }
}

/// The model manager: the full catalog with per-model download, cancel, use and
/// delete, plus manual import of a file the user already has.
struct ModelManagerSheet: View {
    @Bindable var settings: NotchSettings
    @Environment(\.dismiss) private var dismiss

    @State private var store = LocalSpeechModelStore.shared
    @State private var downloads = ModelDownloadManager.shared
    @State private var repositories = ModelRepositoryStore.shared
    @State private var quantSelection: [String: String] = [:]
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var showInstalledOnly = false
    @State private var showAddRepository = false
    @State private var repoInput = ""
    @State private var isResolvingRepo = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            modelList

            if let errorMessage {
                Divider()
                errorBanner(errorMessage)
            }

            Divider()
            footer
        }
        .frame(width: 660, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Add Model Repository", isPresented: $showAddRepository) {
            TextField("owner/name", text: $repoInput)
            Button("Cancel", role: .cancel) { repoInput = "" }
            Button("Add") { addRepository() }
                .disabled(repoInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("Enter the name of a public Hugging Face repository that contains compatible model files.")
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Speech Models")
                    .font(.title2.weight(.semibold))
                Text("Download speech models that run entirely on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Picker("Models", selection: $showInstalledOnly) {
                Text("All").tag(false)
                Text("Installed").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var modelList: some View {
        if visibleModels.isEmpty && customModels.isEmpty {
            ContentUnavailableView {
                Label(showInstalledOnly ? "No Installed Models" : "No Models Available", systemImage: "waveform")
            } description: {
                Text(showInstalledOnly
                    ? "Download a model from the All tab or import one from your Mac."
                    : "The model catalog could not be loaded.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(visibleModels) { model in
                    CatalogModelRow(
                        model: model,
                        quant: quant(for: model),
                        selectedFilename: settings.localModelFilename,
                        onQuantChange: { quantSelection[model.id] = $0 },
                        onDownload: { download(model) },
                        onCancel: { downloads.cancel(selectedFile(for: model).filename) },
                        onDelete: { deleteInstalled(selectedFile(for: model).filename) },
                        onSelect: { settings.localModelFilename = selectedFile(for: model).filename },
                        onRemoveRepository: model.isUserAdded ? { removeRepository(model) } : nil
                    )
                    .listRowInsets(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                }

                if !customModels.isEmpty {
                    Section("Imported Models") {
                        importedSection
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func addRepository() {
        let input = repoInput
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty, !isResolvingRepo else { return }
        Task {
            isResolvingRepo = true
            defer { isResolvingRepo = false }
            do {
                _ = try await repositories.add(repoID: input)
                repoInput = ""
                errorMessage = nil
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }


    private var footer: some View {
        HStack(spacing: 12) {
            Menu {
                Button {
                    showAddRepository = true
                } label: {
                    Label("Hugging Face Repository…", systemImage: "link.badge.plus")
                }
                Button {
                    importModel()
                } label: {
                    Label("Model File…", systemImage: "doc.badge.plus")
                }
            } label: {
                Label("Add Model", systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(isImporting || isResolvingRepo)
            .help("Add Model")

            Button {
                store.revealInFinder()
            } label: {
                Label("Reveal Models in Finder", systemImage: "folder")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Reveal Models in Finder")

            Spacer()

            if isImporting || isResolvingRepo {
                ProgressView()
                    .controlSize(.small)
                Text(isImporting ? "Importing…" : "Adding repository…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var importedSection: some View {
        ForEach(customModels) { model in
            ImportedModelRow(
                model: model,
                isActive: settings.localModelFilename == model.filename,
                onSelect: { settings.localModelFilename = model.filename },
                onDelete: { deleteInstalled(model.filename) }
            )
            .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button {
                errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .foregroundStyle(.red)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.06))
    }

    // MARK: - Model resolution

    /// Show newly bundled repos once if the user had already added them.
    private var allModels: [CatalogModel] {
        let bundled = SpeechModelCatalog.models
        let bundledRepoIDs = Set(bundled.map { $0.repoID.lowercased() })
        return bundled + repositories.models.filter { !bundledRepoIDs.contains($0.repoID.lowercased()) }
    }

    private var visibleModels: [CatalogModel] {
        guard showInstalledOnly else { return allModels }
        return allModels.filter { model in
            model.files.contains { store.model(named: $0.filename) != nil }
        }
    }

    private func quant(for model: CatalogModel) -> String {
        quantSelection[model.id] ?? installedQuant(of: model) ?? model.defaultFile.quant
    }

    private func installedQuant(of model: CatalogModel) -> String? {
        model.files.first { store.model(named: $0.filename) != nil }?.quant
    }

    private func selectedFile(for model: CatalogModel) -> CatalogQuantFile {
        model.file(quant: quant(for: model)) ?? model.defaultFile
    }

    /// Installed files no listed model claims — files the user imported by hand.
    private var customModels: [LocalSpeechModel] {
        let known = Set(allModels.flatMap { $0.files.map(\.filename) })
        return store.models.filter { !known.contains($0.filename) }
    }

    // MARK: - Actions

    private func download(_ model: CatalogModel) {
        let file = selectedFile(for: model)
        downloads.clearError(file.filename)
        errorMessage = nil
        downloads.download(model, file: file)
    }

    private func deleteInstalled(_ filename: String) {
        downloads.discardPartial(filename)
        guard let installed = store.model(named: filename) else { return }
        do {
            try store.delete(installed)
            if settings.localModelFilename == filename {
                settings.localModelFilename = store.models.first?.filename ?? ""
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Drops a user-added repo from the list. Files already downloaded from it
    /// stay on disk and keep working; they simply move to the imported section.
    private func removeRepository(_ model: CatalogModel) {
        repositories.remove(model)
        errorMessage = nil
    }


    private func importModel() {
        let panel = NSOpenPanel()
        panel.title = "Import Speech Model"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.data]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                isImporting = true
                defer { isImporting = false }
                do {
                    let model = try await store.importModel(from: url)
                    settings.localModelFilename = model.filename
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

/// One catalog model: name, capabilities, quant picker, and the single action
/// that applies to its current state (download, cancel, use, or delete).
private struct CatalogModelRow: View {
    let model: CatalogModel
    let quant: String
    let selectedFilename: String
    let onQuantChange: (String) -> Void
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void
    let onSelect: () -> Void
    /// Present only for user-added repos, which can be removed from the list.
    let onRemoveRepository: (() -> Void)?

    @State private var store = LocalSpeechModelStore.shared
    @State private var downloads = ModelDownloadManager.shared

    private var file: CatalogQuantFile { model.file(quant: quant) ?? model.defaultFile }
    private var isInstalled: Bool { store.model(named: file.filename) != nil }
    private var isActive: Bool { selectedFilename == file.filename }
    private var state: ModelDownloadState? { downloads.state(for: file.filename) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 10) {
                        Text(model.name)
                            .font(.headline)
                        modelBadges
                            .font(.caption)
                    }

                    Text(model.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                HStack(spacing: 6) {
                    primaryAction
                    moreActions
                }
            }

            metadataLine

            HStack(spacing: 12) {
                if model.files.count > 1 {
                    Picker("Variant", selection: Binding(get: { quant }, set: onQuantChange)) {
                        ForEach(model.files) { candidate in
                            Text("\(candidate.quant) · \(candidate.sizeMB) MB").tag(candidate.quant)
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 220)
                    .disabled(state?.isActive == true)
                } else {
                    Label("\(file.quant) · \(file.sizeMB) MB", systemImage: "shippingbox")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            progressArea
        }
    }

    @ViewBuilder
    private var modelBadges: some View {
        if model.capabilities.streaming {
            Label("Live", systemImage: "waveform")
                .foregroundStyle(.tint)
        }
        if model.recommended {
            Label("Recommended", systemImage: "star.fill")
                .foregroundStyle(.secondary)
        }
        if model.isUserAdded {
            Label("Added", systemImage: "person.badge.plus")
                .foregroundStyle(.secondary)
        }
    }

    /// Credits the repo the weights come from, the upstream model, and the
    /// license. Several of these models are CC-BY-4.0, where attribution is a
    /// condition of use rather than a courtesy.
    private var metadataLine: some View {
        HStack(spacing: 12) {
            if !model.languageSummary.isEmpty {
                Label(model.languageSummary, systemImage: "globe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            attributionLine
        }
    }

    private var attributionLine: some View {
        Link(destination: model.repoURL) {
            Label(model.attribution, systemImage: "link")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .help("Open \(model.repoID) on Hugging Face")
    }

    @ViewBuilder
    private var progressArea: some View {
        if let state {
            switch state {
            case .queued:
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting to download…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .downloading(let received, let total, let speed):
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(received), total: Double(max(total, 1)))
                        .progressViewStyle(.linear)
                    HStack {
                        Text("\(received / 1_048_576) of \(total / 1_048_576) MB")
                        Spacer()
                        if speed > 0 {
                            Text(ModelDownloadManager.byteRate(speed))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            case .verifying:
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Verifying download…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if !isInstalled {
            let partial = ModelDownloadManager.partialSize(for: file.filename)
            if partial > 0 {
                Label("Paused at \(partial / 1_048_576) MB. Retry to resume.", systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if state?.isActive == true {
            Button("Cancel") { onCancel() }
                .controlSize(.small)
        } else if isInstalled {
            if isActive {
                Label("In Use", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                Button("Use") { onSelect() }
                    .controlSize(.small)
            }
        } else {
            Button(state == nil ? "Download" : "Retry") { onDownload() }
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var moreActions: some View {
        if state?.isActive != true && (isInstalled || onRemoveRepository != nil) {
            Menu {
                if isInstalled {
                    Button("Delete Model", role: .destructive) { onDelete() }
                }
                if let onRemoveRepository {
                    Button("Remove Repository") { onRemoveRepository() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
    }
}

private struct ImportedModelRow: View {
    let model: LocalSpeechModel
    let isActive: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.headline)
                Text("Imported file · \(model.sizeMB) MB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isActive {
                Label("In Use", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                Button("Use") { onSelect() }
                    .controlSize(.small)
            }

            Menu {
                Button("Delete Model", role: .destructive) { onDelete() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
    }
}
