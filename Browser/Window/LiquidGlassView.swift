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

struct BrowserChromeBackground: View {
    enum Effect {
        case liquidGlass(style: NSGlassEffectView.Style, tintColor: NSColor? = nil)
        case material
    }

    let bezelStyle: BrowserBezelStyle
    let cornerRadius: CGFloat
    let effect: Effect
    let profileColor: NSColor?

    init(
        bezelStyle: BrowserBezelStyle,
        cornerRadius: CGFloat,
        effect: Effect,
        profileColor: NSColor? = nil
    ) {
        self.bezelStyle = bezelStyle
        self.cornerRadius = cornerRadius
        self.effect = effect
        self.profileColor = profileColor
    }

    var body: some View {
        if bezelStyle == .simple {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(nsColor: profileColor ?? .black))
        } else {
            switch effect {
            case .liquidGlass(let style, let tintColor):
                LiquidGlassView(
                    style: style,
                    cornerRadius: cornerRadius,
                    tintColor: profileColor?.withAlphaComponent(0.44) ?? tintColor
                )
            case .material:
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
            }
        }
    }
}
