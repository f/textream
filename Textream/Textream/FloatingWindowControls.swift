import SwiftUI

struct FloatingWindowHeader: View {
    @Bindable var settings: NotchSettings
    @State private var showsTextControls = false

    var body: some View {
        HStack(spacing: 12) {
            FloatingWindowDragArea()
                .overlay(alignment: .leading) {
                    Label("Move", systemImage: "line.3.horizontal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .allowsHitTesting(false)
                }
                .help("Drag to move the prompter. Position and size are saved automatically.")

            if settings.showElapsedTime {
                ElapsedTimeView(fontSize: 11)
            }

            Button {
                showsTextControls.toggle()
            } label: {
                Label("\(Int(settings.fontSize)) pt", systemImage: "textformat.size")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("Text size and line spacing")
            .accessibilityLabel("Text size and line spacing")
            .popover(isPresented: $showsTextControls) {
                PrompterTextControls(settings: settings)
                    .padding(16)
                    .frame(width: 290)
                    .environment(\.colorScheme, .dark)
            }
        }
        .frame(height: 30)
        .padding(.horizontal, 14)
        .background(.white.opacity(0.04))
    }
}

private struct FloatingWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            NSCursor.closedHand.push()
            window?.performDrag(with: event)
            NSCursor.pop()
        }
    }
}

struct FloatingWindowResizeGrip: NSViewRepresentable {
    func makeNSView(context: Context) -> ResizeView {
        let view = ResizeView()
        view.toolTip = "Drag to resize the prompter"
        view.setAccessibilityLabel("Resize teleprompter")
        return view
    }

    func updateNSView(_ nsView: ResizeView, context: Context) {}

    final class ResizeView: NSView {
        private var initialFrame: NSRect?
        private var initialMouse = NSPoint.zero

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .frameResize(position: .bottomRight, directions: .all))
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.withAlphaComponent(0.4).setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.5
            for inset: CGFloat in [5, 10] {
                path.move(to: NSPoint(x: bounds.maxX - inset - 3, y: 3))
                path.line(to: NSPoint(x: bounds.maxX - 3, y: inset + 3))
            }
            path.stroke()
        }

        override func mouseDown(with event: NSEvent) {
            initialFrame = window?.frame
            initialMouse = NSEvent.mouseLocation
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window, let initialFrame else { return }
            let mouse = NSEvent.mouseLocation
            let width = max(window.minSize.width, initialFrame.width + mouse.x - initialMouse.x)
            let height = max(window.minSize.height, initialFrame.height - mouse.y + initialMouse.y)
            window.setFrame(
                NSRect(x: initialFrame.minX, y: initialFrame.maxY - height, width: width, height: height),
                display: true
            )
        }

        override func mouseUp(with event: NSEvent) {
            initialFrame = nil
        }
    }
}
