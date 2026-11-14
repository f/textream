import SwiftUI
import UIKit

struct ScriptPaletteEntry: Identifiable {
    let id = UUID()
    var hex: String
}

@Observable
final class ScriptFormattingController {
    var selectedColor: String?
    @ObservationIgnored weak var coordinator: BracketHighlightingTextEditor.Coordinator?
    func applyColor(_ hex: String) { coordinator?.applyColor(hex) }
}

struct ScriptColorBar: View {
    let entries: [ScriptPaletteEntry]
    let formatting: ScriptFormattingController

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(entries) { entry in
                    Button { formatting.applyColor(entry.hex) } label: {
                        Circle()
                            .fill(Color(uiColor: UIColor(rgbHex: entry.hex)))
                            .frame(width: 18, height: 18)
                            .overlay { Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 1) }
                            .frame(width: 32, height: 36)
                            .overlay {
                                if formatting.selectedColor == entry.hex {
                                    Circle().strokeBorder(.tint, lineWidth: 3).frame(width: 26, height: 26)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Text color \(entry.hex)")
                    .accessibilityAddTraits(formatting.selectedColor == entry.hex ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: 36)
    }
}

struct ScriptKeyboardAccessory: View {
    let entries: [ScriptPaletteEntry]
    let formatting: ScriptFormattingController
    let dismissKeyboard: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if entries.count > 1 {
                ScriptColorBar(entries: entries, formatting: formatting)
            }
            Spacer(minLength: 0)
            Button("Done", action: dismissKeyboard)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ScriptPaletteSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Section {
            HStack(spacing: 0) {
                ForEach(model.editorPalette) { entry in
                    PaletteColorSwatch(
                        hex: entry.hex,
                        canDelete: model.editorPalette.count > 1,
                        onChange: { model.setPaletteColor($0, id: entry.id) },
                        onDelete: { model.removePaletteColor(id: entry.id) }
                    )
                    .frame(width: 44, height: 44)
                    .frame(width: 32, height: 32)
                    .frame(maxWidth: .infinity)
                }
                if model.editorPalette.count < AppModel.maximumPaletteColors {
                    Button { model.addPaletteColor() } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .accessibilityLabel("Add palette color")
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Editor Color Palette")
        } footer: {
            Text("Tap a color to customize it. Touch and hold to delete. Quick colors are hidden when only one remains.")
        }
    }
}

private struct PaletteColorSwatch: UIViewRepresentable {
    let hex: String
    var title = "Palette Color"
    var selected = false
    let canDelete: Bool
    var onSelect: (() -> Void)? = nil
    let onChange: (String) -> Void
    let onDelete: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> PaletteSwatchButton {
        let button = PaletteSwatchButton(frame: .zero)
        button.addTarget(context.coordinator, action: #selector(Coordinator.activate), for: .touchUpInside)
        // Keep the menu attached to each native swatch, not the enclosing Form row.
        button.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        context.coordinator.button = button
        return button
    }

    func updateUIView(_ button: PaletteSwatchButton, context: Context) {
        context.coordinator.parent = self
        button.swatchColor = UIColor(rgbHex: hex)
        button.showsSelection = selected
        button.setNeedsLayout()
        button.accessibilityLabel = "\(title) \(hex)"
        button.accessibilityTraits = selected ? [.button, .selected] : [.button]
    }

    static func dismantleUIView(_ button: PaletteSwatchButton, coordinator: Coordinator) {
        coordinator.closePicker()
    }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate, UIColorPickerViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
        var parent: PaletteColorSwatch
        weak var button: UIButton?
        private weak var picker: UIColorPickerViewController?

        init(parent: PaletteColorSwatch) { self.parent = parent }

        @objc func activate() {
            if let select = parent.onSelect { select() }
            else { openPicker() }
        }

        private func openPicker() {
            guard picker == nil, let button, button.window != nil else { return }
            var responder: UIResponder? = button
            while let current = responder, !(current is UIViewController) { responder = current.next }
            guard let presenter = responder as? UIViewController, presenter.presentedViewController == nil else { return }

            let picker = UIColorPickerViewController()
            picker.title = parent.title
            picker.supportsAlpha = false
            picker.selectedColor = UIColor(rgbHex: parent.hex)
            picker.delegate = self
            picker.modalPresentationStyle = .popover
            if let popover = picker.popoverPresentationController {
                popover.sourceView = button
                popover.sourceRect = button.bounds
                popover.permittedArrowDirections = [.up, .down]
                popover.adaptiveSheetPresentationController.detents = [.medium(), .large()]
            }
            picker.presentationController?.delegate = self
            self.picker = picker
            presenter.present(picker, animated: true)
        }

        func closePicker() {
            guard let picker else { return }
            self.picker = nil
            picker.delegate = nil
            picker.presentationController?.delegate = nil
            picker.dismiss(animated: false)
        }

        func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
            guard picker === viewController else { return }
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
            parent.onChange(color.rgbHex)
        }

        func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
            guard picker === viewController else { return }
            picker = nil
            viewController.delegate = nil
            viewController.presentationController?.delegate = nil
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            guard let picker, presentationController.presentedViewController === picker else { return }
            self.picker = nil
            picker.delegate = nil
            presentationController.delegate = nil
        }

        private func preview(for interaction: UIContextMenuInteraction) -> UITargetedPreview? {
            guard let view = interaction.view as? PaletteSwatchButton else { return nil }
            let parameters = UIPreviewParameters()
            parameters.backgroundColor = .clear
            let inset: CGFloat = view.showsSelection ? 0 : 6
            parameters.visiblePath = UIBezierPath(ovalIn: view.bounds.insetBy(dx: inset, dy: inset))
            return UITargetedPreview(view: view, parameters: parameters)
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction, previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
            preview(for: interaction)
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction, previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
            preview(for: interaction)
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                guard let self else { return nil }
                let edit = UIAction(title: "Edit Color", image: UIImage(systemName: "paintpalette")) { [weak self] _ in
                    self?.openPicker()
                }
                let delete = UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: parent.canDelete ? [.destructive] : [.destructive, .disabled]) { [weak self] _ in
                    guard let self, parent.canDelete else { return }
                    parent.onDelete()
                }
                return UIMenu(children: [edit, delete])
            }
        }
    }
}

private final class PaletteSwatchButton: UIButton {
    var swatchColor: UIColor = .white
    var showsSelection = false
    private let dotLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(dotLayer)
        layer.addSublayer(selectionLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dotLayer.frame = bounds
        dotLayer.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 6.5, dy: 6.5)).cgPath
        dotLayer.fillColor = swatchColor.cgColor
        dotLayer.strokeColor = UIColor.separator.cgColor
        dotLayer.lineWidth = 1
        selectionLayer.frame = bounds
        selectionLayer.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5)).cgPath
        selectionLayer.fillColor = UIColor.clear.cgColor
        selectionLayer.strokeColor = tintColor.cgColor
        selectionLayer.lineWidth = 3
        selectionLayer.isHidden = !showsSelection
        CATransaction.commit()
    }
}

struct CuePaletteSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(model.cuePalette) { entry in
                PaletteColorSwatch(
                    hex: entry.hex,
                    title: "Cue Color",
                    selected: model.selectedCueID == entry.id,
                    canDelete: model.cuePalette.count > 1,
                    onSelect: { model.selectedCueID = entry.id },
                    onChange: { model.setCuePaletteColor($0, id: entry.id) },
                    onDelete: { model.removeCuePaletteColor(id: entry.id) }
                )
                .frame(width: 44, height: 44)
                .frame(width: 32, height: 32)
                .frame(maxWidth: .infinity)
            }
            if model.cuePalette.count < AppModel.maximumPaletteColors {
                Button { model.addCuePaletteColor() } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .accessibilityLabel("Add cue color")
            }
        }
        .padding(.vertical, 4)
    }
}
