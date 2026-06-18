import AppKit
import SwiftUI

@MainActor
final class WindowReference: ObservableObject {
    @Published private var generation = 0

    private(set) weak var window: NSWindow?

    func update(_ window: NSWindow) {
        guard self.window !== window else {
            return
        }

        self.window = window
        generation += 1
    }
}

struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                configure(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                configure(window)
            }
        }
    }

    static func configureBrowserWindow(_ window: NSWindow, bezelStyle: BrowserBezelStyle) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.hasShadow = true
        window.contentView?.wantsLayer = true

        switch bezelStyle {
        case .liquidGlass:
            window.backgroundColor = .clear
            window.isOpaque = false
            window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        case .simple:
            window.backgroundColor = .black
            window.isOpaque = true
            window.contentView?.layer?.backgroundColor = NSColor.black.cgColor
        }

        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }
}

struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragHandleView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class DragHandleView: NSView {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.zoom(nil)
        } else {
            window?.performDrag(with: event)
        }
    }
}
