import AppKit
import SwiftUI

struct LiquidGlassView: NSViewRepresentable {
    let style: NSGlassEffectView.Style
    let cornerRadius: CGFloat
    let tintColor: NSColor?

    init(
        style: NSGlassEffectView.Style = .clear,
        cornerRadius: CGFloat,
        tintColor: NSColor? = nil
    ) {
        self.style = style
        self.cornerRadius = cornerRadius
        self.tintColor = tintColor
    }

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSGlassEffectView) {
        view.style = style
        view.cornerRadius = cornerRadius
        view.tintColor = tintColor
    }
}
