//
//  LiquidGlassCompatibility.swift
//  Textream
//
//  Lightweight Liquid Glass adapters with macOS 15 fallback support.
//

import SwiftUI
import AppKit

struct LiquidGlassShape<ShapeType: InsettableShape>: ViewModifier {
    let shape: ShapeType
    let tint: Color?
    let fallbackMaterial: Material
    let shadowOpacity: Double

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if let tint {
                content
                    .glassEffect(.regular.tint(tint), in: shape)
            } else {
                content
                    .glassEffect(.regular, in: shape)
            }
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(fallbackMaterial, in: shape)
            .shadow(color: .black.opacity(shadowOpacity), radius: 12, y: 4)
    }
}

extension View {
    func textreamGlass<S: InsettableShape>(
        in shape: S,
        tint: Color? = nil,
        fallbackMaterial: Material = .ultraThinMaterial,
        shadowOpacity: Double = 0.14
    ) -> some View {
        modifier(
            LiquidGlassShape(
                shape: shape,
                tint: tint,
                fallbackMaterial: fallbackMaterial,
                shadowOpacity: shadowOpacity
            )
        )
    }

    func textreamWindowGlass() -> some View {
        textreamGlass(
            in: RoundedRectangle(cornerRadius: 0, style: .continuous),
            fallbackMaterial: .ultraThinMaterial,
            shadowOpacity: 0
        )
    }
}

struct GlassEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .hudWindow
        nsView.blendingMode = .behindWindow
        nsView.state = .active
        nsView.isEmphasized = true
    }
}

struct LiquidGlassBackdrop<ShapeType: InsettableShape>: View {
    let shape: ShapeType
    let tintOpacity: Double

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.clear)
                .textreamGlass(
                    in: shape,
                    tint: .black.opacity(tintOpacity),
                    fallbackMaterial: .ultraThinMaterial,
                    shadowOpacity: 0.18
                )
            shape
                .fill(.black.opacity(tintOpacity))
        }
        .clipShape(shape)
    }
}
