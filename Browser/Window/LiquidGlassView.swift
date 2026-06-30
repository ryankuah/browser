import AppKit
import SwiftUI

struct LiquidGlassView: NSViewRepresentable {
    let style: NSGlassEffectView.Style
    let cornerRadius: CGFloat
    let maskedCorners: CACornerMask
    let tintColor: NSColor?

    private var usesAllCorners: Bool {
        maskedCorners == [
            .layerMinXMinYCorner,
            .layerMaxXMinYCorner,
            .layerMinXMaxYCorner,
            .layerMaxXMaxYCorner
        ]
    }

    init(
        style: NSGlassEffectView.Style = .clear,
        cornerRadius: CGFloat,
        maskedCorners: CACornerMask = [
            .layerMinXMinYCorner,
            .layerMaxXMinYCorner,
            .layerMinXMaxYCorner,
            .layerMaxXMaxYCorner
        ],
        tintColor: NSColor? = nil
    ) {
        self.style = style
        self.cornerRadius = cornerRadius
        self.maskedCorners = maskedCorners
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
        view.wantsLayer = true
        view.style = style
        view.cornerRadius = usesAllCorners ? cornerRadius : 0
        view.tintColor = tintColor
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.maskedCorners = maskedCorners
        view.layer?.masksToBounds = true
    }
}

struct BrowserChromeBackground: View {
    enum Effect {
        case liquidGlass(style: NSGlassEffectView.Style, tintColor: NSColor? = nil)
        case material
    }

    let bezelStyle: BrowserBezelStyle
    let cornerRadius: CGFloat
    let maskedCorners: CACornerMask
    let effect: Effect
    let profileColor: NSColor?
    let profileTintAlpha: CGFloat

    init(
        bezelStyle: BrowserBezelStyle,
        cornerRadius: CGFloat,
        maskedCorners: CACornerMask = [
            .layerMinXMinYCorner,
            .layerMaxXMinYCorner,
            .layerMinXMaxYCorner,
            .layerMaxXMaxYCorner
        ],
        effect: Effect,
        profileColor: NSColor? = nil,
        profileTintAlpha: CGFloat = 0.44
    ) {
        self.bezelStyle = bezelStyle
        self.cornerRadius = cornerRadius
        self.maskedCorners = maskedCorners
        self.effect = effect
        self.profileColor = profileColor
        self.profileTintAlpha = profileTintAlpha
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
                    maskedCorners: maskedCorners,
                    tintColor: profileColor?.withAlphaComponent(profileTintAlpha) ?? tintColor
                )
            case .material:
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: profileColor ?? .windowBackgroundColor))
                    .background {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.regularMaterial)
                    }
            }
        }
    }
}
