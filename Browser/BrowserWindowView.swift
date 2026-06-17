import AppKit
import SwiftUI

struct BrowserWindowView: View {
    @StateObject private var browser = BrowserState()
    @StateObject private var windowReference = WindowReference()

    @State private var isLeftZoneHovered = false
    @State private var isSidebarHovered = false

    private let topChromeHeight: CGFloat = 48
    private let leftChromeWidth: CGFloat = 56
    private let contentInset: CGFloat = 14
    private let sidebarWidth: CGFloat = 320
    private let shellCornerRadius: CGFloat = 28
    private let webCornerRadius: CGFloat = 18

    private var isSidebarVisible: Bool {
        isLeftZoneHovered || isSidebarHovered
    }

    var body: some View {
        GeometryReader { proxy in
            let webOrigin = CGPoint(
                x: leftChromeWidth + contentInset,
                y: topChromeHeight + contentInset
            )
            let webSize = CGSize(
                width: max(proxy.size.width - webOrigin.x - contentInset, 0),
                height: max(proxy.size.height - webOrigin.y - contentInset, 0)
            )
            let sidebarOverlayWidth = min(sidebarWidth, max(webSize.width, 0))

            ZStack(alignment: .topLeading) {
                LiquidGlassView(
                    style: .clear,
                    cornerRadius: shellCornerRadius,
                    tintColor: NSColor.white.withAlphaComponent(0.03)
                )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false)

                ZStack(alignment: .topLeading) {
                    LiquidGlassView(
                        style: .regular,
                        cornerRadius: webCornerRadius,
                        tintColor: NSColor.white.withAlphaComponent(0.04)
                    )
                        .allowsHitTesting(false)

                    if browser.activeTab?.url != nil {
                        WebView(
                            webView: browser.activeTab?.webView,
                            cornerRadius: webCornerRadius
                        )
                    }

                    if isSidebarVisible {
                        BrowserSidebar(browser: browser, window: windowReference.window)
                            .frame(width: sidebarOverlayWidth, height: webSize.height, alignment: .topLeading)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                            .onHover { isSidebarHovered = $0 }
                    }
                }
                .frame(width: webSize.width, height: webSize.height)
                .clipShape(RoundedRectangle(cornerRadius: webCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: webCornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .offset(x: webOrigin.x, y: webOrigin.y)
                .animation(.easeInOut(duration: 0.16), value: isSidebarVisible)

                Color.clear
                    .frame(
                        width: leftChromeWidth + contentInset,
                        height: max(proxy.size.height - topChromeHeight, 0)
                    )
                    .contentShape(Rectangle())
                    .offset(y: topChromeHeight)
                    .onHover { isLeftZoneHovered = $0 }

                WindowDragHandle()
                    .frame(width: proxy.size.width, height: topChromeHeight)
                    .contentShape(Rectangle())
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .background(
            WindowAccessor { window in
                WindowAccessor.configureLiquidGlassWindow(window)
                windowReference.update(window)
            }
        )
    }
}
