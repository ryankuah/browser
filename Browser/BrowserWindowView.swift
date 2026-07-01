import AppKit
import SwiftUI

private struct PassthroughHoverRegion: NSViewRepresentable {
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> PassthroughHoverView {
        let view = PassthroughHoverView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: PassthroughHoverView, context: Context) {
        nsView.onHover = onHover
    }
}
private final class PassthroughHoverView: NSView {
    var onHover: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

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
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }
}

private struct BrowserContentView: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var browser: BrowserState
    @ObservedObject var session: BrowserSessionController

    let shouldMountWebView: Bool
    let webCornerRadius: CGFloat
    let occlusionRects: [CGRect]
    let onWebViewMounted: () -> Void
    let onRetryFailure: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
                .allowsHitTesting(false)

            if let page = BrowserInternalPage.page(for: tab.url) {
                BrowserInternalPageView(
                    page: page,
                    browser: browser,
                    session: session,
                    onClose: {
                        browser.closeTab(id: tab.id)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure = tab.pageFailure {
                BrowserFailureView(
                    failure: failure,
                    onRetry: onRetryFailure
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            } else if shouldMountWebView {
                WebView(
                    webView: tab.webView,
                    cornerRadius: webCornerRadius,
                    occlusionRects: occlusionRects,
                    onMount: onWebViewMounted
                )
                .id(tab.id)
            }
        }
    }
}

private struct BrowserInternalPageView: View {
    let page: BrowserInternalPage
    @ObservedObject var browser: BrowserState
    @ObservedObject var session: BrowserSessionController
    let onClose: () -> Void

    var body: some View {
        switch page {
        case .settings:
            BrowserFullSettingsPage(browser: browser, onClose: onClose)
        case .history:
            BrowserHistoryPage(browser: browser, onClose: onClose)
        case .mail:
            BrowserMailPage(browser: browser, session: session, onClose: onClose)
        case .dashboard:
            BrowserDashboardPage(browser: browser, session: session, onClose: onClose)
        case .calendar:
            BrowserCalendarPage(browser: browser, session: session, onClose: onClose)
        }
    }
}

private struct WebContentClipModifier: ViewModifier {
    let cornerRadius: CGFloat
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
        }
    }
}

struct BrowserWindowView: View {
    @StateObject private var browser = BrowserState()
    @StateObject private var windowReference = WindowReference()
    @ObservedObject var updateController: BrowserUpdateController
    @ObservedObject var externalURLRouter: BrowserExternalURLRouter
    @ObservedObject var session: BrowserSessionController

    @State private var isLeftZoneHovered = false
    @State private var isSidebarHovered = false
    @State private var isProfileZoneHovered = false
    @State private var isProfileMenuHovered = false
    @State private var isNewTabPromptPresented = false
    @State private var isAddressPromptPresented = false
    @State private var isConsolePresented = false
    @State private var isSettingsPresented = false
    @State private var isFindPresented = false
    @State private var findNavigationRequest: BrowserFindNavigationRequest?
    @State private var commandKeyMonitor: Any?
    @State private var pendingSidebarClose: DispatchWorkItem?
    @State private var pendingProfileMenuClose: DispatchWorkItem?
    @State private var webViewOcclusionRootRects: [CGRect] = []
    @State private var externalURLRegistrationID: UUID?

    private let topChromeHeight: CGFloat = 6
    private let sidebarHoverWidth: CGFloat = 6
    private let contentInset: CGFloat = 6
    private let profileBezelOverlap: CGFloat = 4
    private let profileHoverHeight: CGFloat = 116
    private let profileMenuWidth: CGFloat = 168
    private let profileMenuMaxHeight: CGFloat = 220
    private let sidebarWidth: CGFloat = 236
    private let sidebarCloseDelay: TimeInterval = 0.1
    private let profileMenuCloseDelay: TimeInterval = 0.1
    private let shellCornerRadius: CGFloat = 20
    private var webCornerRadius: CGFloat {
        max(shellCornerRadius - contentInset, 0)
    }

    private var preferredColorScheme: ColorScheme? {
        browser.profilePrefersDarkForeground ? .light : .dark
    }

    private var isSidebarVisible: Bool {
        !browser.isElementFullscreenActive && (isLeftZoneHovered || isSidebarHovered)
    }

    private var isProfileMenuVisible: Bool {
        !browser.isElementFullscreenActive && (isProfileZoneHovered || isProfileMenuHovered)
    }

    var body: some View {
        GeometryReader { proxy in
            let isElementFullscreenActive = browser.isElementFullscreenActive
            let activeContentInset: CGFloat = isElementFullscreenActive ? 0 : contentInset
            let activeTopChromeHeight: CGFloat = isElementFullscreenActive ? 0 : topChromeHeight
            let activeWebCornerRadius: CGFloat = isElementFullscreenActive ? 0 : webCornerRadius
            let isProfileBezelVisible = !isElementFullscreenActive && !browser.profiles.isEmpty
            let rightContentInset = isProfileBezelVisible ? activeContentInset + profileBezelOverlap : activeContentInset
            let webOrigin = CGPoint(
                x: activeContentInset,
                y: activeTopChromeHeight
            )
            let webSize = CGSize(
                width: max(proxy.size.width - activeContentInset - rightContentInset, 0),
                height: max(proxy.size.height - webOrigin.y - activeContentInset, 0)
            )
            let sidebarOverlayWidth = min(sidebarWidth, max(webSize.width, 0))
            let profileMenuHeight = min(
                profileMenuMaxHeight,
                max(CGFloat(browser.profiles.count) * 34 + 16, 50)
            )
            let profileHoverY = webOrigin.y + max((webSize.height - profileHoverHeight) / 2, 0)
            let profileMenuY = webOrigin.y + max((webSize.height - profileMenuHeight) / 2, 0)
            ZStack(alignment: .topLeading) {
                BrowserChromeBackground(
                    bezelStyle: browser.bezelStyle,
                    cornerRadius: shellCornerRadius,
                    effect: .liquidGlass(style: .clear),
                    profileColor: browser.profileNSColor
                )
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                    .allowsHitTesting(false)

                Group {
                    if let activeTab = browser.activeTab {
                        BrowserContentView(
                            tab: activeTab,
                            browser: browser,
                            session: session,
                            shouldMountWebView: browser.shouldMountWebView(for: activeTab),
                            webCornerRadius: activeWebCornerRadius,
                            occlusionRects: isElementFullscreenActive ? [] : webViewOcclusionRects(
                                rootRects: webViewOcclusionRootRects,
                                webOrigin: webOrigin,
                                webSize: webSize
                            ),
                            onWebViewMounted: {
                                browser.webViewDidMount(for: activeTab.id)
                            },
                            onRetryFailure: {
                                browser.retryActivePageFailure()
                            }
                        )
                        .id(activeTab.id)
                    } else {
                        Color.white
                    }
                }
                .frame(width: webSize.width, height: webSize.height, alignment: .topLeading)
                .modifier(WebContentClipModifier(
                    cornerRadius: activeWebCornerRadius,
                    isEnabled: !isElementFullscreenActive
                ))
                .offset(x: webOrigin.x, y: webOrigin.y)
                .animation(.easeInOut(duration: 0.16), value: isSidebarVisible)

                if isSidebarVisible {
                    sidebarOverlay(
                        width: sidebarOverlayWidth,
                        height: webSize.height,
                        leadingCaptureWidth: contentInset
                    )
                        .offset(x: 0, y: webOrigin.y)
                        .zIndex(4)
                }

                if isProfileMenuVisible {
                    profileMenuOverlay(
                        width: profileMenuWidth,
                        height: profileMenuHeight,
                        trailingCaptureWidth: rightContentInset
                    )
                    .offset(
                        x: max(proxy.size.width - profileMenuWidth - rightContentInset, 0),
                        y: profileMenuY
                    )
                    .zIndex(4)
                }

                if !isElementFullscreenActive {
                    PassthroughHoverRegion { isHovered in
                        updateLeftZoneHover(isHovered)
                    }
                        .frame(
                            width: contentInset + sidebarHoverWidth,
                            height: webSize.height
                        )
                        .offset(x: 0, y: webOrigin.y)
                        .zIndex(3)

                    if isProfileBezelVisible {
                        PassthroughHoverRegion { isHovered in
                            updateProfileZoneHover(isHovered)
                        }
                        .frame(
                            width: rightContentInset,
                            height: min(profileHoverHeight, webSize.height)
                        )
                        .offset(
                            x: max(proxy.size.width - rightContentInset, 0),
                            y: profileHoverY
                        )
                        .zIndex(3)
                    }

                    WindowDragHandle()
                        .frame(width: proxy.size.width, height: topChromeHeight)
                        .contentShape(Rectangle())

                    if browser.activeTab?.isLoading == true {
                        LoadingBezelPill()
                            .frame(width: proxy.size.width, height: topChromeHeight)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }

                if isNewTabPromptPresented {
                    NewTabPrompt(
                        browser: browser,
                        bezelStyle: browser.bezelStyle,
                        initialAddressText: "",
                        selectsInitialText: false,
                        suggestionMode: .openNewTab,
                        onSubmit: { address in
                            guard browser.openNewTab(from: address) else {
                                return false
                            }

                            isNewTabPromptPresented = false
                            return true
                        },
                        onSwitchToTab: { tabID in
                            browser.selectTab(id: tabID)
                            isNewTabPromptPresented = false
                        },
                        onCancel: {
                            isNewTabPromptPresented = false
                        }
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .webViewOcclusionRegion()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(2)
                }

                if isAddressPromptPresented {
                    NewTabPrompt(
                        browser: browser,
                        bezelStyle: browser.bezelStyle,
                        initialAddressText: browser.activeTab?.addressText ?? "",
                        selectsInitialText: true,
                        suggestionMode: .navigate,
                        onSubmit: { address in
                            guard browser.navigateAddress(address) else {
                                return false
                            }

                            isAddressPromptPresented = false
                            return true
                        },
                        onSwitchToTab: { tabID in
                            guard let tab = browser.tabs.first(where: { $0.id == tabID }) else {
                                return
                            }

                            guard browser.navigateAddress(tab.addressText) else {
                                return
                            }

                            isAddressPromptPresented = false
                        },
                        onCancel: {
                            isAddressPromptPresented = false
                        }
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .webViewOcclusionRegion()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(2)
                }

                if browser.isOnboardingRequired {
                    ProfileOnboardingOverlay(browser: browser)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .webViewOcclusionRegion()
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .zIndex(6)
                }

                if isConsolePresented {
                    BrowserConsolePanel(
                        messages: browser.consoleMessages,
                        bezelStyle: browser.bezelStyle,
                        profileColor: browser.profileNSColor,
                        onCopy: {
                            copyConsoleMessages(browser.consoleMessages)
                        },
                        onClear: {
                            browser.clearConsoleMessages()
                        },
                        onClose: {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                isConsolePresented = false
                            }
                        }
                    )
                    .frame(width: max(proxy.size.width - 24, 0), height: min(max(proxy.size.height * 0.34, 180), 320))
                    .offset(x: 12, y: max(proxy.size.height - min(max(proxy.size.height * 0.34, 180), 320) - 12, 0))
                    .webViewOcclusionRegion()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(4)
                }

                if isFindPresented {
                    BrowserFindPanel(
                        browser: browser,
                        navigationRequest: findNavigationRequest,
                        bezelStyle: browser.bezelStyle,
                        profileColor: browser.profileNSColor,
                        onClose: {
                            closeFindPanel()
                        }
                    )
                    .frame(width: min(max(proxy.size.width - 32, 0), 360))
                    .offset(
                        x: webOrigin.x + max(webSize.width - min(max(proxy.size.width - 32, 0), 360) - 12, 0),
                        y: webOrigin.y + 12
                    )
                    .webViewOcclusionRegion()
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(6)
                }

                if let oauthURL = session.oauthPresentationURL {
                    BrowserOAuthOverlayView(
                        url: oauthURL,
                        onCallback: { callbackURL in
                            session.handleGoogleOAuthCallback(callbackURL)
                        },
                        onCancel: {
                            session.dismissOAuthPresentation()
                        },
                        onOpenExternally: { externalURL in
                            session.dismissOAuthPresentation()
                            BrowserExternalURLRouter.shared.openExternalURL(externalURL)
                        }
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .webViewOcclusionRegion()
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
                    .zIndex(9)
                }

                BrowserToastStack(browser: browser)
                    .frame(width: min(max(proxy.size.width - 32, 0), 320), alignment: .topTrailing)
                    .offset(
                        x: webOrigin.x + max(webSize.width - min(max(proxy.size.width - 32, 0), 320) - 12, 0),
                        y: webOrigin.y + 12
                    )
                    .zIndex(5)

                if let zoomHUD = browser.zoomHUD {
                    ZStack(alignment: .top) {
                        BrowserZoomHUDView(
                            hud: zoomHUD,
                            bezelStyle: browser.bezelStyle,
                            profileColor: browser.profileNSColor
                        )
                        .padding(.top, webOrigin.y + 12)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(8)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .coordinateSpace(name: BrowserWindowCoordinateSpace.root)
            .onPreferenceChange(WebViewOcclusionPreferenceKey.self) { rects in
                webViewOcclusionRootRects = rects
            }
            .ignoresSafeArea()
            .animation(.easeOut(duration: 0.12), value: isNewTabPromptPresented)
            .animation(.easeOut(duration: 0.12), value: isAddressPromptPresented)
            .animation(.easeInOut(duration: 0.16), value: isSettingsPresented)
            .animation(.easeInOut(duration: 0.16), value: isFindPresented)
            .animation(.easeInOut(duration: 0.16), value: session.oauthPresentationURL)
            .animation(.easeInOut(duration: 0.16), value: isConsolePresented)
            .animation(.easeInOut(duration: 0.16), value: isProfileMenuVisible)
            .animation(.easeInOut(duration: 0.16), value: browser.bezelStyle)
            .animation(.easeInOut(duration: 0.16), value: browser.profileColorHex)
            .animation(.easeInOut(duration: 0.16), value: browser.isOnboardingRequired)
            .animation(.spring(response: 0.24, dampingFraction: 0.86), value: browser.toasts)
            .animation(.easeInOut(duration: 0.16), value: browser.zoomHUD)
        }
        .ignoresSafeArea()
        .preferredColorScheme(preferredColorScheme)
        .background(
            WindowAccessor { window in
                WindowAccessor.configureBrowserWindow(
                    window,
                    bezelStyle: browser.bezelStyle,
                    profileColor: browser.profileNSColor
                )
                windowReference.update(window)
                externalURLRegistrationID = externalURLRouter.register(
                    browser: browser,
                    window: window,
                    existingID: externalURLRegistrationID
                )
            }
        )
        .focusedSceneValue(\.browserCommandActions, BrowserCommandActions(
            newTab: {
                isAddressPromptPresented = false
                isNewTabPromptPresented = true
            },
            reopenClosedTab: {
                browser.reopenLastClosedTab()
            },
            closeTab: {
                browser.closeActiveTab()
            },
            copyPageLink: {
                browser.copyActivePageLink()
            },
            reload: {
                browser.reloadOrStop()
            },
            toggleConsole: {
                isConsolePresented.toggle()
            },
            showFind: {
                showFindPanel()
            },
            findNext: {
                requestFindNavigation(backwards: false)
            },
            findPrevious: {
                requestFindNavigation(backwards: true)
            },
            showHistory: {
                openInternalPage(.history)
            },
            zoomIn: {
                browser.zoomInActiveTab()
            },
            zoomOut: {
                browser.zoomOutActiveTab()
            },
            resetZoom: {
                browser.resetActiveTabZoom()
            },
            showDebugDownloadToast: {
                browser.showDebugDownloadToast()
            },
            showDebugMicrophonePermissionToast: {
                browser.showDebugMicrophonePermissionToast()
            },
            showDebugVideoPermissionToast: {
                browser.showDebugVideoPermissionToast()
            },
            showDebugJavaScriptAlert: {
                browser.showDebugJavaScriptAlert()
            },
            showDebugJavaScriptConfirm: {
                browser.showDebugJavaScriptConfirm()
            },
            showDebugJavaScriptPrompt: {
                browser.showDebugJavaScriptPrompt()
            }
        ))
        .onAppear {
            browser.setCloudSync(session)
            session.migrateLocalStateIfNeeded(from: browser)
            installCommandKeyMonitorIfNeeded()
        }
        .onChange(of: session.isSignedIn) { _, isSignedIn in
            browser.setCloudSync(isSignedIn ? session : nil)
            if isSignedIn {
                session.migrateLocalStateIfNeeded(from: browser)
            }
        }
        .onChange(of: browser.isElementFullscreenActive) { _, isActive in
            guard isActive else {
                return
            }

            cancelPendingSidebarClose()
            cancelPendingProfileMenuClose()
            isLeftZoneHovered = false
            isSidebarHovered = false
            isProfileZoneHovered = false
            isProfileMenuHovered = false
            webViewOcclusionRootRects = []
        }
        .onDisappear {
            externalURLRouter.unregister(id: externalURLRegistrationID)
            externalURLRegistrationID = nil
            removeCommandKeyMonitor()
        }
    }

    private func installCommandKeyMonitorIfNeeded() {
        guard commandKeyMonitor == nil else {
            return
        }

        commandKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard windowReference.window?.isKeyWindow ?? false else {
                return event
            }

            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if modifiers.isEmpty && event.keyCode == 53 {
            }

            guard let characters = event.charactersIgnoringModifiers?.lowercased() else {
                return event
            }

            if modifiers == [.command, .shift] {
                switch characters {
                case "t":
                    browser.reopenLastClosedTab()
                    return nil
                case "g":
                    requestFindNavigation(backwards: true)
                    return nil
                case "=", "+":
                    browser.zoomInActiveTab()
                    return nil
                default:
                    break
                }
            }

            guard modifiers == .command else {
                return event
            }

            if characters == "w" {
                browser.closeActiveTab()
                return nil
            }

            if characters == "f" {
                showFindPanel()
                return nil
            }

            if characters == "g" {
                requestFindNavigation(backwards: false)
                return nil
            }

            if characters == "y" {
                openInternalPage(.history)
                return nil
            }

            if characters == "=" || characters == "+" {
                browser.zoomInActiveTab()
                return nil
            }

            if characters == "-" {
                browser.zoomOutActiveTab()
                return nil
            }

            if characters == "0" {
                browser.resetActiveTabZoom()
                return nil
            }

            if let shortcutIndex = Int(characters), (1...9).contains(shortcutIndex) {
                browser.selectNavigationItem(atShortcutIndex: shortcutIndex)
                return nil
            }

            return event
        }
    }

    private func removeCommandKeyMonitor() {
        guard let commandKeyMonitor else {
            return
        }

        NSEvent.removeMonitor(commandKeyMonitor)
        self.commandKeyMonitor = nil
    }

    private func showFindPanel() {
        withAnimation(.easeInOut(duration: 0.16)) {
            isFindPresented = true
        }
    }

    private func closeFindPanel() {
        browser.clearActiveFindSelection()
        withAnimation(.easeInOut(duration: 0.16)) {
            isFindPresented = false
        }
    }

    private func requestFindNavigation(backwards: Bool) {
        if !isFindPresented {
            showFindPanel()
        }

        findNavigationRequest = BrowserFindNavigationRequest(backwards: backwards)
    }

    private func openInternalPage(_ page: BrowserInternalPage) {
        isFindPresented = false
        isSettingsPresented = false
        _ = browser.navigateAddress(page.url.absoluteString)
    }

    private func sidebarOverlay(width: CGFloat, height: CGFloat, leadingCaptureWidth: CGFloat = 0) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())

            BrowserSidebar(
                browser: browser,
                updateController: updateController,
                isSettingsPresented: $isSettingsPresented,
                window: windowReference.window,
                cornerRadius: webCornerRadius,
                onOpenFullSettings: {
                    openInternalPage(.settings)
                },
                onOpenAddressPrompt: {
                    isNewTabPromptPresented = false
                    isAddressPromptPresented = true
                },
                onOpenHistory: {
                    openInternalPage(.history)
                }
            )
            .frame(width: width, height: height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: webCornerRadius, style: .continuous))
            .offset(x: leadingCaptureWidth)
        }
        .frame(width: width + leadingCaptureWidth, height: height, alignment: .topLeading)
        .webViewOcclusionRegion()
        .transition(.move(edge: .leading))
        .onHover { isHovered in
            updateSidebarHover(isHovered)
        }
    }

    private func profileMenuOverlay(width: CGFloat, height: CGFloat, trailingCaptureWidth: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
                .contentShape(Rectangle())

            ProfileBezelSwitcher(browser: browser)
                .frame(width: width, height: height, alignment: .top)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .offset(x: -trailingCaptureWidth)
        }
        .frame(width: width + trailingCaptureWidth, height: height, alignment: .topTrailing)
        .webViewOcclusionRegion()
        .transition(.move(edge: .trailing).combined(with: .opacity))
        .onHover { isHovered in
            updateProfileMenuHover(isHovered)
        }
    }

    private func updateLeftZoneHover(_ isHovered: Bool) {
        if isHovered {
            cancelPendingSidebarClose()
            withAnimation(.easeInOut(duration: 0.16)) {
                isLeftZoneHovered = true
            }
            return
        }

        scheduleSidebarClose {
            isLeftZoneHovered = false
        }
    }

    private func updateSidebarHover(_ isHovered: Bool) {
        if isHovered {
            cancelPendingSidebarClose()
            withAnimation(.easeInOut(duration: 0.16)) {
                isLeftZoneHovered = false
                isSidebarHovered = true
            }
            return
        }

        scheduleSidebarClose {
            isSidebarHovered = false
        }
    }

    private func scheduleSidebarClose(_ update: @escaping () -> Void) {
        pendingSidebarClose?.cancel()

        let workItem = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.16)) {
                update()
            }
            pendingSidebarClose = nil
        }

        pendingSidebarClose = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + sidebarCloseDelay, execute: workItem)
    }

    private func cancelPendingSidebarClose() {
        pendingSidebarClose?.cancel()
        pendingSidebarClose = nil
    }

    private func updateProfileZoneHover(_ isHovered: Bool) {
        if isHovered {
            cancelPendingProfileMenuClose()
            withAnimation(.easeInOut(duration: 0.16)) {
                isProfileZoneHovered = true
            }
            return
        }

        scheduleProfileMenuClose {
            isProfileZoneHovered = false
        }
    }

    private func updateProfileMenuHover(_ isHovered: Bool) {
        if isHovered {
            cancelPendingProfileMenuClose()
            withAnimation(.easeInOut(duration: 0.16)) {
                isProfileZoneHovered = false
                isProfileMenuHovered = true
            }
            return
        }

        scheduleProfileMenuClose {
            isProfileMenuHovered = false
        }
    }

    private func scheduleProfileMenuClose(_ update: @escaping () -> Void) {
        pendingProfileMenuClose?.cancel()

        let workItem = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.16)) {
                update()
            }
            pendingProfileMenuClose = nil
        }

        pendingProfileMenuClose = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + profileMenuCloseDelay, execute: workItem)
    }

    private func cancelPendingProfileMenuClose() {
        pendingProfileMenuClose?.cancel()
        pendingProfileMenuClose = nil
    }

    private func webViewOcclusionRects(rootRects: [CGRect], webOrigin: CGPoint, webSize: CGSize) -> [CGRect] {
        let webRect = CGRect(origin: webOrigin, size: webSize)

        return rootRects.compactMap { rootRect in
            let intersection = rootRect.intersection(webRect)
            guard !intersection.isNull,
                  intersection.width > 0,
                  intersection.height > 0 else {
                return nil
            }

            return CGRect(
                x: intersection.minX - webOrigin.x,
                y: intersection.minY - webOrigin.y,
                width: intersection.width,
                height: intersection.height
            )
        }
    }

    private func copyConsoleMessages(_ messages: [BrowserConsoleMessage]) {
        let text = messages.map { message in
            [
                BrowserConsoleRow.timeString(for: message.date),
                message.level.uppercased(),
                message.source,
                message.message,
                message.url ?? ""
            ]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
            .joined(separator: "\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
