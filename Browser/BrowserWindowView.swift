import SwiftUI

struct BrowserWindowView: View {
    let url: URL

    @State private var isSidebarOpen = false
    @State private var isBorderHovered = false
    @State private var isSidebarHovered = false
    @State private var closeRequestID = 0

    private let sidebarWidth: CGFloat = 240
    private let webCornerRadius: CGFloat = 9

    private var isSidebarVisible: Bool {
        isSidebarOpen
    }

    var body: some View {
        GeometryReader { proxy in
            let borderThickness = WindowBorder.thickness
            let headerHeight = WindowBorder.headerHeight
            let contentWidth = max(proxy.size.width - (borderThickness * 2), 0)
            let contentHeight = max(proxy.size.height - headerHeight - borderThickness, 0)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: webCornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: webCornerRadius, style: .continuous)
                            .fill(.white.opacity(0.06))
                    }
                    .frame(width: contentWidth, height: contentHeight)
                    .offset(x: borderThickness, y: headerHeight)
                    .allowsHitTesting(false)

                WebView(
                    url: url,
                    acceptsMouseEvents: !isSidebarVisible,
                    cornerRadius: webCornerRadius
                )
                    .frame(width: contentWidth, height: contentHeight)
                    .offset(x: borderThickness, y: headerHeight)

                ZStack(alignment: .leading) {
                    BrowserSidebar()
                        .frame(width: sidebarWidth, height: contentHeight, alignment: .topLeading)
                        .offset(x: isSidebarVisible ? 0 : -sidebarWidth)
                        .animation(.easeInOut(duration: 0.16), value: isSidebarVisible)
                }
                    .frame(width: sidebarWidth, height: contentHeight, alignment: .leading)
                    .clipShape(
                        UnevenRoundedRectangle(
                            cornerRadii: RectangleCornerRadii(
                                topLeading: webCornerRadius,
                                bottomLeading: webCornerRadius
                            ),
                            style: .continuous
                        )
                    )
                    .clipped()
                    .offset(x: borderThickness, y: headerHeight)
                    .allowsHitTesting(isSidebarVisible)
                    .onHover { isHovered in
                        if isHovered {
                            guard isSidebarOpen else {
                                isSidebarHovered = false
                                return
                            }

                            isSidebarHovered = true
                            cancelSidebarClose()
                        } else {
                            isSidebarHovered = false
                            requestSidebarClose()
                        }
                    }

                BorderHoverTrigger { isHovered in
                    isBorderHovered = isHovered

                    if isHovered {
                        openSidebar()
                    } else {
                        requestSidebarClose()
                    }
                }

                WindowDragHandle()
                    .frame(maxWidth: .infinity, minHeight: headerHeight, maxHeight: headerHeight)

                WindowBorder()
                    .allowsHitTesting(false)
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .background(WindowAccessor(configure: WindowAccessor.hideTitlebarAndTrafficLights))
    }

    private func openSidebar() {
        cancelSidebarClose()
        isSidebarOpen = true
    }

    private func cancelSidebarClose() {
        closeRequestID += 1
    }

    private func requestSidebarClose() {
        closeRequestID += 1
        let requestID = closeRequestID

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if closeRequestID == requestID && !isBorderHovered && !isSidebarHovered {
                isSidebarOpen = false
            }
        }
    }
}
