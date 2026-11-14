import SwiftUI
import AppKit

struct PaletteEntry: Identifiable {
    let id = UUID()
    var hex: String
}

struct QuickColorPalette: View {
    let entries: [PaletteEntry]
    let formatting: EditorFormattingController

    var body: some View {
        HStack(spacing: 2) {
            ForEach(entries) { entry in
                Button { formatting.applyColor(entry.hex) } label: {
                    Circle()
                        .fill(Color(nsColor: NSColor(rgbHex: entry.hex)))
                        .frame(width: 12, height: 12)
                        .overlay { Circle().strokeBorder(.black.opacity(0.15), lineWidth: 1) }
                        .frame(width: 24, height: 24)
                        .overlay {
                            if formatting.selectedColor == entry.hex {
                                Circle().strokeBorder(Color.accentColor, lineWidth: 3)
                                    .frame(width: 22, height: 22)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help("Use \(entry.hex) for selected or new text")
                .accessibilityLabel("Text color \(entry.hex)")
                .accessibilityValue(formatting.selectedColor == entry.hex ? "Selected" : "Not selected")
            }
        }
        .padding(.horizontal, 6)
        .fixedSize()
    }
}

/// AppKit owns both the drag session and color panel; SwiftUI never feeds panel.color back during a drag.
struct PaletteSettingsRow: NSViewRepresentable {
    let settings: NotchSettings
    let entries: [PaletteEntry]

    var isCue = false

    func makeNSView(context: Context) -> PaletteRow {
        let row = PaletteRow(settings: settings, isCue: isCue)
        row.refresh()
        return row
    }

    func updateNSView(_ row: PaletteRow, context: Context) {
        _ = entries.map(\.hex)
        _ = settings.cueColorHex
        row.refresh()
    }

    static func dismantleNSView(_ row: PaletteRow, coordinator: ()) { row.closePicker() }
}

class PaletteRow: NSView {
    static let pasteboardType = NSPasteboard.PasteboardType("dev.fka.textream.palette-entry")
    private static weak var pickerOwner: PaletteRow?
    let settings: NotchSettings
    let isCue: Bool
    var entries: [PaletteEntry] {
        get { isCue ? settings.cuePalette : settings.editorPalette }
        set {
            if isCue { settings.cuePalette = newValue }
            else { settings.editorPalette = newValue }
        }
    }
    private var buttons: [UUID: PaletteSwatch] = [:]
    private var editingID: UUID?
    private var panelCloseObserver: NSObjectProtocol?
    private var insertionIndex: Int?
    private let addButton = NSButton()
    private let step: CGFloat = 34

    init(settings: NotchSettings, isCue: Bool) {
        self.settings = settings
        self.isCue = isCue
        super.init(frame: .zero)
        registerForDraggedTypes([Self.pasteboardType])
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add color")
        addButton.bezelStyle = .regularSquare
        addButton.isBordered = false
        addButton.target = self
        addButton.action = #selector(addColor)
        addSubview(addButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let addSlots = entries.count < NotchSettings.maximumPaletteColors ? 1 : 0
        return NSSize(width: step * CGFloat(entries.count + addSlots), height: 34)
    }

    func refresh() {
        let ids = Set(entries.map(\.id))
        for id in Array(buttons.keys) where !ids.contains(id) {
            buttons.removeValue(forKey: id)?.removeFromSuperview()
            if editingID == id { closePicker() }
        }
        for (index, entry) in entries.enumerated() {
            let button = buttons[entry.id] ?? PaletteSwatch(entryID: entry.id, row: self)
            if buttons[entry.id] == nil { buttons[entry.id] = button; addSubview(button) }
            button.frame = NSRect(x: CGFloat(index) * step, y: isCue ? 0 : 2,
                                  width: isCue ? 34 : 30, height: isCue ? 34 : 30)
            let selected = isCue && settings.selectedCueID == entry.id
            let imageSize: CGFloat = isCue ? 34 : 26
            let swatchInset: CGFloat = isCue ? 5 : 1
            button.imageScaling = .scaleNone
            button.image = NSImage(size: NSSize(width: imageSize, height: imageSize), flipped: false) { rect in
                let swatch = NSBezierPath(roundedRect: rect.insetBy(dx: swatchInset, dy: swatchInset), xRadius: 7, yRadius: 7)
                NSColor(rgbHex: entry.hex).setFill()
                swatch.fill()
                NSColor.separatorColor.setStroke()
                swatch.stroke()
                if selected {
                    NSColor.controlAccentColor.setStroke()
                    let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), xRadius: 11, yRadius: 11)
                    ring.lineWidth = 3
                    ring.stroke()
                }
                return true
            }
            button.setAccessibilityLabel("\(isCue ? "Select cue" : "Edit palette") color \(entry.hex)")
            button.setAccessibilityValue(selected ? "Selected" : "Not selected")
        }
        addButton.frame = NSRect(x: CGFloat(entries.count) * step, y: 2, width: 30, height: 30)
        addButton.isEnabled = entries.count < NotchSettings.maximumPaletteColors
        addButton.isHidden = !addButton.isEnabled
        invalidateIntrinsicContentSize()
    }

    @objc private func addColor() {
        guard entries.count < NotchSettings.maximumPaletteColors else { return }
        let preset = NotchSettings.defaultEditorPalette.first { !entries.map(\.hex).contains($0) } ?? "#8e8e93"
        entries.append(PaletteEntry(hex: preset))
    }

    func openPicker(for id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        let panel = NSColorPanel.shared
        Self.pickerOwner?.closePicker(closePanel: false)
        panel.setTarget(nil)
        panel.setAction(nil)
        editingID = id
        Self.pickerOwner = self
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = NSColor(rgbHex: entry.hex)
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panelCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            self?.closePicker(closePanel: false)
        }
        if let window {
            panel.setFrameOrigin(NSPoint(x: window.frame.midX - panel.frame.width / 2,
                                         y: window.frame.midY - panel.frame.height / 2))
        }
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ panel: NSColorPanel) {
        guard Self.pickerOwner === self, let id = editingID,
              let index = entries.firstIndex(where: { $0.id == id }) else { return }
        // Pattern colors cannot be represented by our RGB-only palette.
        // Retain the last valid color instead of silently replacing it with white.
        guard let rgb = panel.color.usingColorSpace(.sRGB) else { return }
        let hex = rgb.rgbHex
        if entries[index].hex != hex { entries[index].hex = hex }
    }

    static func closeActivePicker() {
        pickerOwner?.closePicker()
    }

    func closePicker(closePanel: Bool = true) {
        guard editingID != nil else { return }
        editingID = nil
        if let panelCloseObserver {
            NotificationCenter.default.removeObserver(panelCloseObserver)
            self.panelCloseObserver = nil
        }
        let panel = NSColorPanel.shared
        if Self.pickerOwner === self {
            Self.pickerOwner = nil
            panel.setTarget(nil)
            panel.setAction(nil)
            if closePanel { panel.close() }
        }
    }

    func removeColor(id: UUID) {
        guard entries.count > 1 else { return }
        if editingID == id { closePicker() }
        entries.removeAll { $0.id == id }
    }

    private func draggedID(_ info: NSDraggingInfo) -> UUID? {
        info.draggingPasteboard.string(forType: Self.pasteboardType).flatMap(UUID.init(uuidString:))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let id = draggedID(sender), buttons[id] != nil else { return [] }
        let point = convert(sender.draggingLocation, from: nil)
        insertionIndex = min(entries.count, max(0, Int((point.x + 2) / step)))
        needsDisplay = true
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { insertionIndex = nil; needsDisplay = true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let id = draggedID(sender), let source = entries.firstIndex(where: { $0.id == id }) else { return false }
        let target = insertionIndex ?? source
        var reordered = entries
        let entry = reordered.remove(at: source)
        reordered.insert(entry, at: min(reordered.count, max(0, target - (source < target ? 1 : 0))))
        entries = reordered
        insertionIndex = nil
        needsDisplay = true
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let index = insertionIndex {
            NSColor.controlAccentColor.setFill()
            NSRect(x: max(0, CGFloat(index) * step - 3), y: 1, width: 2, height: 32).fill()
        }
    }

    func dragEnded(id: UUID, point: NSPoint, operation: NSDragOperation, cancelled: Bool) {
        insertionIndex = nil
        needsDisplay = true
        guard !cancelled, operation.isEmpty, entries.count > 1, let window else { return }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        // A missed insertion within the row must never delete a color.
        guard !bounds.insetBy(dx: -10, dy: -12).contains(local) else { return }
        removeColor(id: id)
    }
}

class PaletteSwatch: NSButton, NSDraggingSource {
    let entryID: UUID
    weak var row: PaletteRow?
    private var cancelled = false
    private var escapeMonitor: Any?

    init(entryID: UUID, row: PaletteRow) {
        self.entryID = entryID
        self.row = row
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        target = self
        action = #selector(selectOrEdit)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func editColor() { row?.openPicker(for: entryID) }
    @objc private func selectOrEdit() {
        guard let row else { return }
        if row.isCue, let entry = row.entries.first(where: { $0.id == entryID }) {
            row.settings.selectedCueID = entry.id
        } else { editColor() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let edit = NSMenuItem(title: "Edit Color", action: #selector(editColor), keyEquivalent: "")
        edit.target = self
        menu.addItem(edit)
        let item = NSMenuItem(title: "Delete", action: #selector(deleteColor), keyEquivalent: "")
        item.target = self
        item.isEnabled = (row?.entries.count ?? 0) > 1
        menu.addItem(item)
        return menu
    }

    @objc private func deleteColor() { row?.removeColor(id: entryID) }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                if row?.isCue == true && event.clickCount == 2 { editColor() }
                else { selectOrEdit() }
                return
            }
            guard hypot(next.locationInWindow.x - event.locationInWindow.x,
                        next.locationInWindow.y - event.locationInWindow.y) > 4 else { continue }
            let item = NSPasteboardItem()
            item.setString(entryID.uuidString, forType: PaletteRow.pasteboardType)
            let draggingItem = NSDraggingItem(pasteboardWriter: item)
            draggingItem.setDraggingFrame(bounds, contents: image)
            cancelled = false
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] key in
                if key.keyCode == 53 { self?.cancelled = true }
                return key
            }
            beginDraggingSession(with: [draggingItem], event: next, source: self)
            return
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        row?.dragEnded(id: entryID, point: screenPoint, operation: operation, cancelled: cancelled)
    }
}
