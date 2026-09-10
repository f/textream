//
//  LocalModelSettingsSection.swift
//  Textream
//
//  Settings controls for the local (custom Whisper-family) speech engine:
//  model list, import, reveal in Finder, and delete.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LocalModelSettingsSection: View {
    @Bindable var settings: NotchSettings
    @State private var store = LocalSpeechModelStore.shared
    @State private var isImporting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Local Model")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Button("Import…") { importModel() }
                    .controlSize(.small)
                    .disabled(isImporting)
                Button("Show Folder") { store.revealInFinder() }
                    .controlSize(.small)
            }

            if store.models.isEmpty {
                Text("No models found. Import a Whisper-family .bin or .gguf file, or drop one into the models folder.")
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

                if let selected = store.model(named: settings.localModelFilename) {
                    HStack {
                        Text(selected.filename)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Delete", role: .destructive) { delete(selected) }
                            .controlSize(.small)
                    }
                }
            }

            Text("Runs entirely on this Mac. Whisper models transcribe in ~1.5 s chunks; streaming models (Parakeet, Nemotron, Moonshine) track words live.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if isImporting {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Importing…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
        .onAppear {
            store.refresh()
            ensureSelection()
        }
    }

    private func ensureSelection() {
        guard !store.models.isEmpty else { return }
        if settings.localModelFilename.isEmpty || store.model(named: settings.localModelFilename) == nil {
            settings.localModelFilename = store.models[0].filename
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

    private func delete(_ model: LocalSpeechModel) {
        do {
            try store.delete(model)
            if settings.localModelFilename == model.filename {
                settings.localModelFilename = ""
            }
            ensureSelection()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
