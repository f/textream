//
//  LocalModelSettingsSection.swift
//  Textream
//
//  Settings controls for the local (Whisper-family) speech engine. The section
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
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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

            Text("Runs entirely on this Mac. Whisper models transcribe in ~1.5 s chunks; streaming models (Parakeet, Moonshine Streaming) track words live.")
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

    private var statusColor: Color {
        if activeDownloadCount > 0 { return .accentColor }
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
    @State private var quantSelection: [String: String] = [:]
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var showInstalledOnly = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visibleModels.enumerated()), id: \.element.id) { index, model in
                        if index > 0 { Divider() }
                        CatalogModelRow(
                            model: model,
                            quant: quant(for: model),
                            selectedFilename: settings.localModelFilename,
                            onQuantChange: { quantSelection[model.id] = $0 },
                            onDownload: { download(model) },
                            onCancel: { downloads.cancel(selectedFile(for: model).filename) },
                            onDelete: { deleteInstalled(selectedFile(for: model).filename) },
                            onSelect: { settings.localModelFilename = selectedFile(for: model).filename }
                        )
                        .padding(.horizontal, 16)
                    }

                    if !customModels.isEmpty {
                        Divider()
                        importedSection
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()
            footer
        }
        .frame(width: 560, height: 520)
        .background(.ultraThinMaterial)
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Speech Models")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Picker("", selection: $showInstalledOnly) {
                    Text("All").tag(false)
                    Text("Installed").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }

            Text("Models download from Hugging Face and run entirely on this Mac. Each download is checksum verified before it is installed.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Import…") { importModel() }
                .controlSize(.regular)
                .disabled(isImporting)
            Button("Show Folder") { store.revealInFinder() }
                .controlSize(.regular)

            if isImporting {
                ProgressView().controlSize(.small)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            Spacer()

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .padding(12)
    }

    private var importedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Imported")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            ForEach(customModels) { model in
                HStack {
                    Text("\(model.displayName) — \(model.sizeMB) MB")
                        .font(.system(size: 11))
                    Spacer()
                    if settings.localModelFilename == model.filename {
                        Text("Active")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tint)
                    } else {
                        Button("Use") { settings.localModelFilename = model.filename }
                            .controlSize(.small)
                    }
                    Button("Delete", role: .destructive) { deleteInstalled(model.filename) }
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Model resolution

    private var visibleModels: [CatalogModel] {
        guard showInstalledOnly else { return SpeechModelCatalog.models }
        return SpeechModelCatalog.models.filter { model in
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

    /// Installed files the catalog does not know about — user imports.
    private var customModels: [LocalSpeechModel] {
        store.models.filter { SpeechModelCatalog.model(containing: $0.filename) == nil }
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

    @State private var store = LocalSpeechModelStore.shared
    @State private var downloads = ModelDownloadManager.shared

    private var file: CatalogQuantFile { model.file(quant: quant) ?? model.defaultFile }
    private var isInstalled: Bool { store.model(named: file.filename) != nil }
    private var isActive: Bool { selectedFilename == file.filename }
    private var state: ModelDownloadState? { downloads.state(for: file.filename) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.name)
                    .font(.system(size: 12, weight: .medium))
                if model.capabilities.streaming {
                    Text("STREAMING")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tint)
                }
                if model.recommended {
                    Text("RECOMMENDED")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                actionButtons
            }

            Text("\(model.description) — \(model.languageSummary)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Picker("", selection: Binding(get: { quant }, set: onQuantChange)) {
                    ForEach(model.files) { candidate in
                        Text("\(candidate.quant) · \(candidate.sizeMB) MB").tag(candidate.quant)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 150)
                .disabled(state?.isActive == true)

                ScoreBar(label: "Speed", value: model.normalizedSpeed)
                ScoreBar(label: "Accuracy", value: model.normalizedAccuracy)
                Spacer()
            }

            progressArea
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var progressArea: some View {
        if let state {
            switch state {
            case .queued:
                ProgressView().progressViewStyle(.linear)
            case .downloading(let received, let total, let speed):
                VStack(alignment: .leading, spacing: 2) {
                    ProgressView(value: Double(received), total: Double(max(total, 1)))
                        .progressViewStyle(.linear)
                    Text("\(received / 1_048_576) / \(total / 1_048_576) MB" + (speed > 0 ? " — \(ModelDownloadManager.byteRate(speed))" : ""))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            case .verifying:
                Text("Verifying checksum…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if !isInstalled {
            let partial = ModelDownloadManager.partialSize(for: file.filename)
            if partial > 0 {
                Text("Paused at \(partial / 1_048_576) MB. Download resumes from here.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if state?.isActive == true {
            Button("Cancel") { onCancel() }
                .controlSize(.small)
        } else if isInstalled {
            if isActive {
                Text("Active")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tint)
            } else {
                Button("Use") { onSelect() }
                    .controlSize(.small)
            }
            Button("Delete", role: .destructive) { onDelete() }
                .controlSize(.small)
        } else {
            Button(state == nil ? "Download" : "Retry") { onDownload() }
                .controlSize(.small)
        }
    }
}

private struct ScoreBar: View {
    let label: String
    let value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            ProgressView(value: min(max(value, 0), 1))
                .progressViewStyle(.linear)
                .frame(width: 60)
        }
    }
}
