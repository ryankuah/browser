import AppKit
import SwiftUI

struct CursorModifier: ViewModifier {
    let cursor: NSCursor

    func body(content: Content) -> some View {
        content
            .overlay {
                CursorRegion(cursor: cursor)
                    .allowsHitTesting(false)
            }
    }
}

private struct CursorRegion: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorRegionView {
        CursorRegionView(cursor: cursor)
    }

    func updateNSView(_ nsView: CursorRegionView, context: Context) {
        nsView.cursor = cursor
    }
}

private final class CursorRegionView: NSView {
    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    var cursor: NSCursor {
        didSet {
            guard cursor !== oldValue else {
                return
            }

            window?.invalidateCursorRects(for: self)
            if isHovering {
                setCursor()
            }
        }
    }

    init(cursor: NSCursor) {
        self.cursor = cursor
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        setCursor()
    }

    override func mouseMoved(with event: NSEvent) {
        setCursor()
    }

    override func cursorUpdate(with event: NSEvent) {
        setCursor()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        NSCursor.arrow.set()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: cursor)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    private func setCursor() {
        cursor.set()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isHovering else {
                return
            }

            self.cursor.set()
        }
    }
}

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        modifier(CursorModifier(cursor: cursor))
    }
}
