import AVFoundation
import AVKit
import Photos
import SwiftUI

struct SavedRecordingsGridLayout {
    static let spacing: CGFloat = 8
    static let horizontalPadding: CGFloat = 16

    static func columnCount(for width: CGFloat) -> Int {
        switch width {
        case ..<600: 2
        case ..<900: 4
        default: min(6, max(4, Int((width - horizontalPadding * 2) / 170)))
        }
    }

    static func itemWidth(for width: CGFloat) -> CGFloat {
        let count = CGFloat(columnCount(for: width))
        return max(1, (width - horizontalPadding * 2 - spacing * (count - 1)) / count)
    }
}

struct SavedRecordingsGallery: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var store: SavedRecordingsStore
    @State private var selectedRecording: SavedRecording?
    @State private var isSelecting = false
    @State private var selectedIdentifiers: Set<String> = []
    @State private var deletionErrorMessage: String?

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let width = geometry.size.width
                Group {
                    if store.isLoading {
                        ProgressView("Loading recordings…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if store.authorizationState == .denied {
                        photosAccessView
                    } else if store.recordings.isEmpty {
                        ContentUnavailableView(
                            "No Saved Recordings",
                            systemImage: "video",
                            description: Text(
                                "Videos you record with Textream will appear here after they are saved to Photos."
                            )
                        )
                    } else {
                        recordingsGrid(width: width)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Recordings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { galleryToolbar }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isSelecting { selectionToolbar }
            }
        }
        .task { await store.loadRecordings() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, !store.isDeleting else { return }
            Task { await store.refreshIfAuthorized() }
        }
        .onChange(of: store.recordings.map(\.assetIdentifier)) { _, identifiers in
            selectedIdentifiers.formIntersection(identifiers)
            if identifiers.isEmpty { isSelecting = false }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(store.isDeleting || store.isEditing)
        .fullScreenCover(item: $selectedRecording) { recording in
            SavedRecordingPlayer(recording: recording, store: store)
        }
        .alert("Unable to Delete", isPresented: deletionAlertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionErrorMessage ?? "The selected recordings could not be deleted.")
        }
    }

    @ToolbarContentBuilder
    private var galleryToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            if isSelecting {
                Button("Cancel") { finishSelecting() }
                    .disabled(store.isDeleting)
            } else {
                Button("Done") { dismiss() }
                    .disabled(store.isEditing)
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            if !isSelecting, !store.recordings.isEmpty {
                Button("Select") { isSelecting = true }
                    .disabled(store.isDeleting || store.isEditing)
            }
        }
    }

    private func recordingsGrid(width: CGFloat) -> some View {
        let count = SavedRecordingsGridLayout.columnCount(for: width)
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: SavedRecordingsGridLayout.spacing),
            count: count
        )
        return ScrollView {
            if store.authorizationState == .limited {
                limitedAccessNotice
                    .padding(.horizontal, SavedRecordingsGridLayout.horizontalPadding)
                    .padding(.top, 8)
            }

            LazyVGrid(columns: columns, spacing: SavedRecordingsGridLayout.spacing) {
                ForEach(store.recordings) { recording in
                    Button {
                        handleTap(recording)
                    } label: {
                        recordingTile(recording)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            selectedIdentifiers = [recording.assetIdentifier]
                            isSelecting = true
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                    }
                }
            }
            .padding(.horizontal, SavedRecordingsGridLayout.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
    }

    private var selectionToolbar: some View {
        HStack(spacing: 12) {
            Button(allVisibleRecordingsAreSelected ? "Deselect All" : "Select All") {
                if allVisibleRecordingsAreSelected {
                    selectedIdentifiers.removeAll()
                } else {
                    selectedIdentifiers = Set(store.recordings.map(\.assetIdentifier))
                }
            }
            .disabled(store.isDeleting)

            Spacer(minLength: 8)

            Text(selectionCountText)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)

            Button(role: .destructive) {
                deleteSelection()
            } label: {
                Group {
                    if store.isDeleting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.secondary)
                    } else {
                        Image(systemName: "trash")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                .frame(width: 32, height: 32)
                .foregroundStyle(.red)
                .glassEffect(.regular.interactive(), in: .circle)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tint(.red)
            .disabled(selectedIdentifiers.isEmpty || store.isDeleting)
            .accessibilityLabel("Delete from Photos")
            .accessibilityHint("Deletes the selected recordings from Photos")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private func recordingTile(_ recording: SavedRecording) -> some View {
        let isSelected = selectedIdentifiers.contains(recording.assetIdentifier)
        return ZStack(alignment: .bottomLeading) {
            Color.black
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(uiImage: recording.thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.78)],
                startPoint: .center,
                endPoint: .bottom
            )

            HStack(alignment: .bottom) {
                Text(recording.createdAt, format: .dateTime.month(.abbreviated).day())
                Spacer()
                Text(Self.durationText(recording.duration))
                    .monospacedDigit()
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(9)

            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.9), isSelected ? .indigo : .black.opacity(0.45))
                    .font(.system(size: 25, weight: .semibold))
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .clipShape(.rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? Color.indigo : .white.opacity(0.12), lineWidth: isSelected ? 3 : 1)
        }
        .contentShape(.rect(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Recording from \(recording.createdAt.formatted(date: .abbreviated, time: .shortened))"
        )
        .accessibilityValue(
            isSelecting
                ? "\(Self.durationText(recording.duration)), \(isSelected ? "Selected" : "Not selected")"
                : Self.durationText(recording.duration)
        )
        .accessibilityHint(isSelecting ? "Double tap to change selection" : "Double tap to play")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("savedRecordingTile")
    }

    private var photosAccessView: some View {
        ContentUnavailableView {
            Label("Photos Access Is Off", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Allow Photos access to view and manage videos recorded with Textream.")
        } actions: {
            Button("Open Settings") { openSettings() }
                .buttonStyle(.glassProminent)
        }
    }

    private var limitedAccessNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.badge.exclamationmark")
            Text("Only recordings included in your limited Photos access are shown.")
                .font(.caption)
            Spacer(minLength: 8)
            Button("Manage") { openSettings() }
                .font(.caption.weight(.semibold))
        }
        .padding(12)
        .background(.thinMaterial, in: .rect(cornerRadius: 14))
    }

    private var deletionAlertBinding: Binding<Bool> {
        Binding(
            get: { deletionErrorMessage != nil },
            set: { if !$0 { deletionErrorMessage = nil } }
        )
    }

    private var allVisibleRecordingsAreSelected: Bool {
        !store.recordings.isEmpty
            && selectedIdentifiers == Set(store.recordings.map(\.assetIdentifier))
    }

    private var selectionCountText: String {
        selectedIdentifiers.isEmpty
            ? "Select recordings"
            : "\(selectedIdentifiers.count) selected"
    }

    private func handleTap(_ recording: SavedRecording) {
        if isSelecting {
            if !selectedIdentifiers.insert(recording.assetIdentifier).inserted {
                selectedIdentifiers.remove(recording.assetIdentifier)
            }
        } else {
            selectedRecording = recording
        }
    }

    private func finishSelecting() {
        isSelecting = false
        selectedIdentifiers.removeAll()
    }

    private func deleteSelection() {
        let identifiers = selectedIdentifiers
        guard !identifiers.isEmpty else { return }
        Task {
            do {
                let deleted = try await store.deleteRecordings(with: identifiers)
                selectedIdentifiers.subtract(deleted)
                if store.recordings.isEmpty { isSelecting = false }
            } catch {
                let nsError = error as NSError
                guard nsError.domain == PHPhotosErrorDomain,
                      nsError.code == PHPhotosError.userCancelled.rawValue else {
                    deletionErrorMessage = error.localizedDescription
                    return
                }
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

private struct SavedRecordingPlayer: View {
    @Environment(\.dismiss) private var dismiss
    let store: SavedRecordingsStore
    @State private var recording: SavedRecording
    @State private var player: AVPlayer?
    @State private var didFail = false
    @State private var isPreparingEditor = false
    @State private var isSavingEdit = false
    @State private var editorRequest: NativeVideoEditorRequest?
    @State private var editingErrorMessage: String?

    init(recording: SavedRecording, store: SavedRecordingsStore) {
        self.store = store
        _recording = State(initialValue: recording)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else if didFail {
                    ContentUnavailableView(
                        "Recording Unavailable",
                        systemImage: "video.slash",
                        description: Text(
                            "The video may have been removed from Photos or is not available on this device."
                        )
                    )
                    .foregroundStyle(.white)
                } else {
                    ProgressView("Loading recording…")
                        .tint(.white)
                        .foregroundStyle(.white)
                }
            }
            .navigationTitle(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { prepareNativeEditor() }
                        .disabled(
                            player == nil
                                || didFail
                                || isPreparingEditor
                                || isSavingEdit
                        )
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(
                            isPreparingEditor
                                || isSavingEdit
                                || editorRequest != nil
                                || store.isEditing
                        )
                }
            }
        }
        .overlay {
            if isPreparingEditor || isSavingEdit {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    ProgressView(
                        isSavingEdit ? "Saving edited copy…" : "Preparing editor…"
                    )
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                    .background(.regularMaterial, in: .rect(cornerRadius: 16))
                }
            }
        }
        .task(id: recording.assetIdentifier) {
            await loadAndPlayRecording()
        }
        .onDisappear {
            guard editorRequest == nil else { return }
            player?.pause()
        }
        .fullScreenCover(item: $editorRequest) { request in
            NativeVideoEditor(request: request) { result in
                finishNativeEditor(result, sourceURL: request.sourceURL)
            }
            .ignoresSafeArea()
        }
        .alert("Unable to Edit", isPresented: editingAlertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(editingErrorMessage ?? "The recording could not be edited.")
        }
    }

    private var editingAlertBinding: Binding<Bool> {
        Binding(
            get: { editingErrorMessage != nil },
            set: { if !$0 { editingErrorMessage = nil } }
        )
    }

    private func loadAndPlayRecording() async {
        didFail = false
        player?.pause()
        player = nil
        // A newly-created Photos asset can be persisted before its AVAsset is
        // visible to the next synchronous fetch. Retry briefly so the edited
        // copy begins playing instead of showing a false unavailable state.
        for attempt in 0..<6 {
            if let asset = await store.videoAsset(for: recording), !Task.isCancelled {
                let loadedPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset.asset))
                player = loadedPlayer
                loadedPlayer.play()
                return
            }
            guard !Task.isCancelled else { return }
            if attempt < 5 {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        didFail = true
    }

    private func prepareNativeEditor() {
        guard !isPreparingEditor, !isSavingEdit else { return }
        player?.pause()
        isPreparingEditor = true
        Task {
            do {
                let sourceURL = try await store.beginEditing(recording)
                guard UIVideoEditorController.canEditVideo(atPath: sourceURL.path) else {
                    removeEditWorkspace(containing: sourceURL)
                    throw SavedRecordingsEditError.nativeEditorUnavailable
                }
                isPreparingEditor = false
                editorRequest = NativeVideoEditorRequest(sourceURL: sourceURL)
            } catch is CancellationError {
                isPreparingEditor = false
                store.finishEditing()
                player?.play()
            } catch {
                isPreparingEditor = false
                store.finishEditing()
                editingErrorMessage = error.localizedDescription
                player?.play()
            }
        }
    }

    private func finishNativeEditor(
        _ result: NativeVideoEditorResult,
        sourceURL: URL
    ) {
        editorRequest = nil
        switch result {
        case .cancelled:
            removeEditWorkspace(containing: sourceURL)
            store.finishEditing()
            player?.play()
        case .failed(let error):
            removeEditWorkspace(containing: sourceURL)
            store.finishEditing()
            editingErrorMessage = error.localizedDescription
            player?.play()
        case .saved(let editedURL):
            isSavingEdit = true
            Task {
                defer {
                    removeEditWorkspace(containing: sourceURL)
                    SavedRecordingsStore.removeTemporaryVideo(at: editedURL)
                    isSavingEdit = false
                }
                do {
                    recording = try await store.saveEditedRecording(at: editedURL)
                } catch {
                    editingErrorMessage = error.localizedDescription
                    player?.play()
                }
            }
        }
    }

    private func removeEditWorkspace(containing videoURL: URL) {
        SavedRecordingsStore.removeTemporaryVideo(at: videoURL.deletingLastPathComponent())
    }
}

struct NativeVideoEditorRequest: Identifiable {
    let id = UUID()
    let sourceURL: URL
}

enum NativeVideoEditorResult {
    case saved(URL)
    case cancelled
    case failed(Error)
}

/// UIKit's public video editor provides the same native trimming timeline used
/// by the system media picker without relying on a private Photos URL scheme.
@MainActor
struct NativeVideoEditor: UIViewControllerRepresentable {
    let request: NativeVideoEditorRequest
    let completion: @MainActor (NativeVideoEditorResult) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> UIVideoEditorController {
        Self.makeController(
            request: request,
            delegate: context.coordinator
        )
    }

    static func makeController(
        request: NativeVideoEditorRequest,
        delegate: Coordinator
    ) -> UIVideoEditorController {
        let editor = UIVideoEditorController()
        editor.delegate = delegate
        configure(editor, sourceURL: request.sourceURL)
        return editor
    }

    static func configure(_ editor: UIVideoEditorController, sourceURL: URL) {
        editor.videoPath = sourceURL.path
        editor.videoMaximumDuration = 0
        editor.videoQuality = .typeHigh
    }

    func updateUIViewController(
        _ uiViewController: UIVideoEditorController,
        context: Context
    ) {}

    final class Coordinator: NSObject,
        UIVideoEditorControllerDelegate,
        UINavigationControllerDelegate
    {
        private let completion: @MainActor (NativeVideoEditorResult) -> Void
        private var didComplete = false

        init(completion: @escaping @MainActor (NativeVideoEditorResult) -> Void) {
            self.completion = completion
        }

        func videoEditorController(
            _ editor: UIVideoEditorController,
            didSaveEditedVideoToPath editedVideoPath: String
        ) {
            finish(with: .saved(URL(fileURLWithPath: editedVideoPath)))
        }

        func videoEditorControllerDidCancel(_ editor: UIVideoEditorController) {
            finish(with: .cancelled)
        }

        func videoEditorController(
            _ editor: UIVideoEditorController,
            didFailWithError error: Error
        ) {
            finish(with: .failed(error))
        }

        private func finish(with result: NativeVideoEditorResult) {
            guard !didComplete else { return }
            didComplete = true
            completion(result)
        }
    }
}

#if DEBUG
#Preview("Mixed orientations") {
    SavedRecordingsGallery(
        store: SavedRecordingsStore(
            previewRecordings: [
                SavedRecording(
                    assetIdentifier: "landscape",
                    thumbnail: SavedRecordingsGallery.previewThumbnail(
                        size: CGSize(width: 640, height: 360),
                        color: .systemIndigo,
                        label: "16:9"
                    ),
                    createdAt: .now,
                    duration: 68
                ),
                SavedRecording(
                    assetIdentifier: "portrait",
                    thumbnail: SavedRecordingsGallery.previewThumbnail(
                        size: CGSize(width: 360, height: 640),
                        color: .systemOrange,
                        label: "9:16"
                    ),
                    createdAt: .now.addingTimeInterval(-3_600),
                    duration: 7
                ),
                SavedRecording(
                    assetIdentifier: "square",
                    thumbnail: SavedRecordingsGallery.previewThumbnail(
                        size: CGSize(width: 480, height: 480),
                        color: .systemGreen,
                        label: "1:1"
                    ),
                    createdAt: .now.addingTimeInterval(-7_200),
                    duration: 125
                )
            ]
        )
    )
}

@MainActor
private extension SavedRecordingsGallery {
    static func previewThumbnail(size: CGSize, color: UIColor, label: String) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let text = NSAttributedString(
                string: label,
                attributes: [
                    .font: UIFont.systemFont(ofSize: min(size.width, size.height) * 0.18, weight: .bold),
                    .foregroundColor: UIColor.white
                ]
            )
            let textSize = text.size()
            text.draw(
                at: CGPoint(
                    x: (size.width - textSize.width) / 2,
                    y: (size.height - textSize.height) / 2
                )
            )
        }
    }
}
#endif
