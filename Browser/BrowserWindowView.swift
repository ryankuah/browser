import AppKit
import SwiftUI

private enum BrowserWindowCoordinateSpace {
    static let root = "BrowserWindowRoot"
}

private struct WebViewOcclusionPreferenceKey: PreferenceKey {
    static let defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

private extension View {
    func webViewOcclusionRegion() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: WebViewOcclusionPreferenceKey.self,
                    value: [proxy.frame(in: .named(BrowserWindowCoordinateSpace.root))]
                )
            }
        }
    }
}

struct BrowserWindowView: View {
    @StateObject private var browser = BrowserState()
    @StateObject private var windowReference = WindowReference()
    @ObservedObject var updateController: BrowserUpdateController

    @State private var isLeftZoneHovered = false
    @State private var isSidebarHovered = false
    @State private var isNewTabPromptPresented = false
    @State private var isAddressPromptPresented = false
    @State private var isConsolePresented = false
    @State private var isSettingsPresented = false
    @State private var isFullSettingsPresented = false
    @State private var commandKeyMonitor: Any?
    @State private var pendingSidebarClose: DispatchWorkItem?
    @State private var webViewOcclusionRootRects: [CGRect] = []

    private let topChromeHeight: CGFloat = 6
    private let sidebarHoverWidth: CGFloat = 6
    private let contentInset: CGFloat = 6
    private let profileBezelOverlap: CGFloat = 4
    private let sidebarWidth: CGFloat = 236
    private let sidebarCloseDelay: TimeInterval = 0.1
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

    var body: some View {
        GeometryReader { proxy in
            let webOrigin = CGPoint(
                x: contentInset,
                y: topChromeHeight
            )
            let webSize = CGSize(
                width: max(proxy.size.width - (contentInset * 2), 0),
                height: max(proxy.size.height - webOrigin.y - contentInset, 0)
            )
            let sidebarOverlayWidth = min(sidebarWidth, max(webSize.width, 0))
            ZStack(alignment: .topLeading) {
                BrowserChromeBackground(
                    bezelStyle: browser.bezelStyle,
                    cornerRadius: shellCornerRadius,
                    effect: .liquidGlass(style: .clear),
                    profileColor: browser.profileNSColor
                )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false)

                if !browser.isElementFullscreenActive && !browser.profiles.isEmpty {
                    ProfileBezelSwitcher(browser: browser)
                        .frame(
                            width: contentInset + profileBezelOverlap,
                            height: max(proxy.size.height - topChromeHeight - contentInset, 0)
                        )
                        .offset(
                            x: max(proxy.size.width - contentInset - profileBezelOverlap, 0),
                            y: topChromeHeight
                        )
                        .webViewOcclusionRegion()
                }

                ZStack(alignment: .topLeading) {
                    Color.white
                        .allowsHitTesting(false)

                    if let activeTab = browser.activeTab, browser.shouldMountWebView(for: activeTab) {
                        WebView(
                            webView: activeTab.webView,
                            cornerRadius: webCornerRadius,
                            occlusionRects: webViewOcclusionRects(
                                rootRects: webViewOcclusionRootRects,
                                webOrigin: webOrigin,
                                webSize: webSize
                            ),
                            onMount: {
                                browser.webViewDidMount(for: activeTab.id)
                            }
                        )
                        .id(activeTab.id)
                    }

                    if isSidebarVisible {
                        BrowserSidebar(
                            browser: browser,
                            updateController: updateController,
                            isSettingsPresented: $isSettingsPresented,
                            window: windowReference.window,
                            cornerRadius: webCornerRadius,
                            onOpenFullSettings: {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    isFullSettingsPresented = true
                                    isSettingsPresented = false
                                }
                            },
                            onOpenAddressPrompt: {
                                isNewTabPromptPresented = false
                                isAddressPromptPresented = true
                            }
                        )
                            .frame(width: sidebarOverlayWidth, height: webSize.height, alignment: .topLeading)
                            .webViewOcclusionRegion()
                            .transition(.move(edge: .leading))
                            .onHover { isHovered in
                                updateSidebarHover(isHovered)
                            }
                    }
                }
                .frame(width: webSize.width, height: webSize.height, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: webCornerRadius, style: .continuous))
                .offset(x: webOrigin.x, y: webOrigin.y)
                .animation(.easeInOut(duration: 0.16), value: isSidebarVisible)

                if !browser.isElementFullscreenActive {
                    Color.clear
                        .frame(
                            width: sidebarHoverWidth,
                            height: webSize.height
                        )
                        .contentShape(Rectangle())
                        .offset(x: webOrigin.x, y: webOrigin.y)
                        .webViewOcclusionRegion()
                        .onHover { isHovered in
                            updateLeftZoneHover(isHovered)
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

                if isFullSettingsPresented {
                    BrowserFullSettingsPage(
                        browser: browser,
                        onClose: {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                isFullSettingsPresented = false
                            }
                        }
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .webViewOcclusionRegion()
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
                    .zIndex(7)
                }

                BrowserToastStack(browser: browser)
                    .frame(width: min(max(proxy.size.width - 32, 0), 320), alignment: .topTrailing)
                    .offset(
                        x: webOrigin.x + max(webSize.width - min(max(proxy.size.width - 32, 0), 320) - 12, 0),
                        y: webOrigin.y + 12
                    )
                    .zIndex(5)
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
            .animation(.easeInOut(duration: 0.16), value: isFullSettingsPresented)
            .animation(.easeInOut(duration: 0.16), value: isConsolePresented)
            .animation(.easeInOut(duration: 0.16), value: browser.bezelStyle)
            .animation(.easeInOut(duration: 0.16), value: browser.profileColorHex)
            .animation(.easeInOut(duration: 0.16), value: browser.isOnboardingRequired)
            .animation(.spring(response: 0.24, dampingFraction: 0.86), value: browser.toasts)
            .animation(.easeInOut(duration: 0.16), value: browser.isElementFullscreenActive)
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
            installCommandKeyMonitorIfNeeded()
        }
        .onDisappear {
            removeCommandKeyMonitor()
        }
    }

    private func installCommandKeyMonitorIfNeeded() {
        guard commandKeyMonitor == nil else {
            return
        }

        commandKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard windowReference.window?.isKeyWindow ?? false,
                  let characters = event.charactersIgnoringModifiers?.lowercased() else {
                return event
            }

            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if modifiers == [.command, .shift], characters == "t" {
                browser.reopenLastClosedTab()
                return nil
            }

            guard modifiers == .command else {
                return event
            }

            if characters == "w" {
                browser.closeActiveTab()
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

private struct BrowserFullSettingsPage: View {
    @ObservedObject var browser: BrowserState
    let onClose: () -> Void

    @State private var isAddingProfile = false
    @State private var editingProfileID: BrowserProfile.ID?

    var body: some View {
        ZStack {
            BrowserChromeBackground(
                bezelStyle: browser.bezelStyle,
                cornerRadius: 0,
                effect: .liquidGlass(
                    style: .regular,
                    tintColor: NSColor.black.withAlphaComponent(0.16)
                ),
                profileColor: browser.profileNSColor,
                simpleFillOpacity: 0.72
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header

                Divider()
                    .opacity(0.45)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        FullSettingsSection(title: "General", systemName: "magnifyingglass") {
                            VStack(alignment: .leading, spacing: 10) {
                                FullSettingsLabel("Search Engine")

                                FullSettingsSegmentedControl {
                                    ForEach(BrowserSearchEngine.allCases, id: \.rawValue) { engine in
                                        FullSettingsSegmentButton(
                                            title: engine.label,
                                            isSelected: browser.searchEngine == engine
                                        ) {
                                            browser.setSearchEngine(engine)
                                        }
                                    }
                                }
                            }

                            FullSettingsDivider()

                            FullSettingsValueRow(
                                title: "Downloads",
                                value: browser.downloadsDirectoryDisplayPath,
                                systemName: "folder"
                            )

                            HStack(spacing: 8) {
                                FullSettingsActionButton(title: "Open Folder", systemName: "arrow.up.forward.app") {
                                    browser.openDownloadsFolder()
                                }

                                FullSettingsActionButton(title: "Copy Path", systemName: "doc.on.doc") {
                                    browser.copyDownloadsDirectoryPath()
                                }

                                Spacer()
                            }
                        }

                        FullSettingsSection(title: "Appearance", systemName: "paintpalette") {
                            FullSettingsLabel("Bezel Style")

                            FullSettingsSegmentedControl {
                                ForEach(BrowserBezelStyle.allCases, id: \.rawValue) { style in
                                    FullSettingsSegmentButton(
                                        title: style.label,
                                        isSelected: browser.bezelStyle == style
                                    ) {
                                        browser.setBezelStyle(style)
                                    }
                                }
                            }
                        }

                        FullSettingsSection(title: "Profiles", systemName: "person.crop.circle") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(browser.profiles) { profile in
                                    FullSettingsProfileRow(
                                        profile: profile,
                                        isSelected: browser.selectedProfileID == profile.id,
                                        canDelete: browser.profiles.count > 1,
                                        onSelect: {
                                            browser.switchProfile(id: profile.id)
                                        },
                                        onEdit: {
                                            withAnimation(.easeInOut(duration: 0.14)) {
                                                isAddingProfile = false
                                                editingProfileID = profile.id
                                            }
                                        },
                                        onDelete: {
                                            withAnimation(.easeInOut(duration: 0.14)) {
                                                if editingProfileID == profile.id {
                                                    editingProfileID = nil
                                                }
                                                browser.deleteProfile(id: profile.id)
                                            }
                                        }
                                    )
                                }
                            }

                            if isAddingProfile {
                                ProfileCreationPanel(
                                    title: "New Profile",
                                    defaultName: "",
                                    defaultColor: NSColor(hexString: BrowserProfile.defaultColorHex) ?? .systemBlue,
                                    profileColor: browser.profileNSColor
                                ) { name, colorHex in
                                    browser.createProfile(name: name, colorHex: colorHex)
                                    withAnimation(.easeInOut(duration: 0.14)) {
                                        isAddingProfile = false
                                    }
                                }
                            }

                            if let editingProfile {
                                ProfileCreationPanel(
                                    title: "Edit Profile",
                                    defaultName: editingProfile.displayName,
                                    defaultColor: NSColor(hexString: editingProfile.colorHex) ?? .systemBlue,
                                    submitTitle: "Save",
                                    profileColor: browser.profileNSColor
                                ) { name, colorHex in
                                    browser.updateProfile(id: editingProfile.id, name: name, colorHex: colorHex)
                                    withAnimation(.easeInOut(duration: 0.14)) {
                                        editingProfileID = nil
                                    }
                                }
                            }

                            HStack {
                                FullSettingsActionButton(
                                    title: isAddingProfile ? "Cancel" : "Add Profile",
                                    systemName: isAddingProfile ? "xmark" : "plus"
                                ) {
                                    withAnimation(.easeInOut(duration: 0.14)) {
                                        editingProfileID = nil
                                        isAddingProfile.toggle()
                                    }
                                }

                                Spacer()
                            }
                        }

                    }
                    .padding(18)
                }
            }
            .frame(width: 560, height: 620)
            .background {
                BrowserChromeBackground(
                    bezelStyle: browser.bezelStyle,
                    cornerRadius: 12,
                    effect: .liquidGlass(
                        style: .regular,
                        tintColor: NSColor.black.withAlphaComponent(0.12)
                    ),
                    profileColor: browser.profileNSColor
                )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.14), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.28), radius: 30, y: 18)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .semibold))

            Text("Settings")
                .font(.system(size: 16, weight: .semibold))

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            }
            .accessibilityLabel("Close Settings")
            .help("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var editingProfile: BrowserProfile? {
        guard let editingProfileID else {
            return nil
        }

        return browser.profiles.first { $0.id == editingProfileID }
    }
}

private struct FullSettingsSection<Content: View>: View {
    let title: String
    let systemName: String
    let content: Content

    init(title: String, systemName: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemName = systemName
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FullSettingsLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
    }
}

private struct FullSettingsDivider: View {
    var body: some View {
        Divider()
            .opacity(0.38)
    }
}

private struct FullSettingsValueRow: View {
    let title: String
    let value: String
    let systemName: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 18)
                .foregroundStyle(.secondary)

            Text(title)
                .font(.system(size: 12, weight: .medium))

            Spacer()

            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct FullSettingsSegmentedControl<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 6) {
            content
        }
    }
}

private struct FullSettingsSegmentButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.13) : isHovered ? Color.primary.opacity(0.07) : Color.clear)
        }
        .onHover { isHovered = $0 }
        .cursor(.pointingHand)
        .accessibilityLabel(title)
        .help(title)
    }
}

private struct FullSettingsActionButton: View {
    let title: String
    let systemName: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .frame(height: 30)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.13) : Color.primary.opacity(0.09))
        }
        .onHover { isHovered = $0 }
        .cursor(.pointingHand)
        .accessibilityLabel(title)
        .help(title)
    }
}

private struct FullSettingsProfileRow: View {
    let profile: BrowserProfile
    let isSelected: Bool
    let canDelete: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSelect) {
                HStack(spacing: 9) {
                    Circle()
                        .fill(Color(nsColor: NSColor(hexString: profile.colorHex) ?? .systemBlue))
                        .frame(width: 16, height: 16)

                    Text(profile.displayName)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)

                    Spacer()

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                    }
                }
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit \(profile.displayName)")
            .help("Edit")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canDelete)
            .accessibilityLabel("Delete \(profile.displayName)")
            .help("Delete")
        }
        .padding(.horizontal, 10)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.1) : Color.clear)
        }
    }
}

private struct FullSettingsPermissionButton: View {
    let kind: BrowserMediaDeviceKind
    let isAllowed: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: kind.iconSystemName)
                    .font(.system(size: 12, weight: .semibold))

                Text(kind.accessibilityLabel.replacingOccurrences(of: " Permission", with: ""))
                    .font(.system(size: 12, weight: .semibold))

                Text(isAllowed ? "Allowed" : "Blocked")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 30)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isAllowed ? Color.green.opacity(0.18) : Color.primary.opacity(0.08))
        }
        .accessibilityLabel(kind.accessibilityLabel)
        .help(kind.accessibilityLabel)
    }
}

private struct ProfileBezelSwitcher: View {
    @ObservedObject var browser: BrowserState

    private let swatchWidth: CGFloat = 10

    var body: some View {
        ScrollView {
            VStack(spacing: 3) {
                ForEach(browser.profiles) { profile in
                    Button {
                        browser.switchProfile(id: profile.id)
                    } label: {
                        Rectangle()
                            .fill(Color(nsColor: NSColor(hexString: profile.colorHex) ?? .systemBlue))
                            .frame(width: swatchWidth, height: browser.selectedProfileID == profile.id ? 44 : 32)
                            .overlay {
                                if browser.selectedProfileID == profile.id {
                                    Rectangle()
                                        .stroke(Color.white.opacity(0.95), lineWidth: 1)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .cursor(.pointingHand)
                    .accessibilityLabel(profile.displayName)
                    .help(profile.displayName)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
            .padding(.bottom, 10)
        }
        .scrollIndicators(.hidden)
    }
}

private struct ProfileOnboardingOverlay: View {
    @ObservedObject var browser: BrowserState

    var body: some View {
        ZStack {
            BrowserChromeBackground(
                bezelStyle: browser.bezelStyle,
                cornerRadius: 0,
                effect: .liquidGlass(
                    style: .regular,
                    tintColor: NSColor.black.withAlphaComponent(0.2)
                ),
                profileColor: browser.profileNSColor
            )
            .opacity(0.96)
            .ignoresSafeArea()

            ProfileCreationPanel(
                title: "Create Profile",
                defaultName: "Personal",
                defaultColor: NSColor(hexString: BrowserProfile.defaultColorHex) ?? .systemBlue,
                profileColor: browser.profileNSColor
            ) { name, colorHex in
                browser.createProfile(name: name, colorHex: colorHex)
            }
            .frame(width: 320)
            .padding(20)
        }
    }
}

struct ProfileCreationPanel: View {
    let title: String
    let defaultName: String
    let defaultColor: NSColor
    var submitTitle = "Create"
    var profileColor: NSColor?
    let onCreate: (String, String) -> Void

    @State private var name: String
    @State private var selectedColorHex: String

    init(
        title: String,
        defaultName: String,
        defaultColor: NSColor,
        submitTitle: String = "Create",
        profileColor: NSColor? = nil,
        onCreate: @escaping (String, String) -> Void
    ) {
        self.title = title
        self.defaultName = defaultName
        self.defaultColor = defaultColor
        self.submitTitle = submitTitle
        self.profileColor = profileColor
        self.onCreate = onCreate
        _name = State(initialValue: defaultName)
        _selectedColorHex = State(initialValue: defaultColor.hexString)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 8) {
                Text("Color")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                ProfilePresetColorRow(
                    title: "Light",
                    colorHexes: BrowserProfile.lightPresetColorHexes,
                    selectedColorHex: $selectedColorHex
                )

                ProfilePresetColorRow(
                    title: "Dark",
                    colorHexes: BrowserProfile.darkPresetColorHexes,
                    selectedColorHex: $selectedColorHex
                )
            }

            Button {
                onCreate(name, selectedColorHex)
            } label: {
                Text(submitTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
            }
            .buttonStyle(.plain)
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .foregroundStyle(.primary)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.12))
            }
        }
        .padding(12)
        .background {
            BrowserChromeBackground(
                bezelStyle: .liquidGlass,
                cornerRadius: 10,
                effect: .liquidGlass(
                    style: .regular,
                    tintColor: NSColor.white.withAlphaComponent(0.1)
                ),
                profileColor: profileColor
            )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.16), lineWidth: 1)
        }
            .shadow(color: Color.black.opacity(0.22), radius: 24, y: 12)
    }
}

private struct ProfilePresetColorRow: View {
    let title: String
    let colorHexes: [String]
    @Binding var selectedColorHex: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 7) {
                ForEach(colorHexes, id: \.self) { colorHex in
                    Button {
                        selectedColorHex = colorHex
                    } label: {
                        Circle()
                            .fill(Color(nsColor: NSColor(hexString: colorHex) ?? .systemBlue))
                            .frame(width: 22, height: 22)
                            .overlay {
                                Circle()
                                    .stroke(Color.primary.opacity(isSelected(colorHex) ? 0.82 : 0.18), lineWidth: isSelected(colorHex) ? 2 : 1)
                            }
                            .overlay {
                                if isSelected(colorHex) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle((NSColor(hexString: colorHex) ?? .systemBlue).prefersDarkForeground ? .black : .white)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(colorHex)
                    .help(colorHex)
                }
            }
        }
    }

    private func isSelected(_ colorHex: String) -> Bool {
        selectedColorHex.caseInsensitiveCompare(colorHex) == .orderedSame
    }
}

private struct BrowserToastStack: View {
    @ObservedObject var browser: BrowserState

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(browser.toasts.prefix(4)) { toast in
                BrowserToastView(
                    toast: toast,
                    bezelStyle: browser.bezelStyle,
                    profileColor: browser.profileNSColor,
                    onAllow: {
                        browser.allowMediaPermissionToast(id: toast.id)
                    },
                    onDeny: {
                        browser.denyMediaPermissionToast(id: toast.id)
                    },
                    onOpenDownload: {
                        guard let downloadID = toast.downloadID else {
                            return
                        }

                        browser.openDownloadedFile(id: downloadID)
                    },
                    onDismiss: {
                        browser.dismissToast(id: toast.id)
                    }
                )
                .webViewOcclusionRegion()
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topTrailing)
        .allowsHitTesting(!browser.toasts.isEmpty)
    }
}

private struct BrowserToastView: View {
    let toast: BrowserToast
    let bezelStyle: BrowserBezelStyle
    let profileColor: NSColor
    let onAllow: () -> Void
    let onDeny: () -> Void
    let onOpenDownload: () -> Void
    let onDismiss: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var isHovered = false

    private let notificationCornerRadius: CGFloat = 24

    private var iconColor: Color {
        switch toast.status {
        case .pending:
            return .accentColor
        case .success:
            return .green
        case .failure:
            return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: toast.iconSystemName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(toast.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if toast.kind != .mediaPermission {
                        Text(toast.message)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let progressFraction = toast.progressFraction, toast.status == .pending {
                ProgressView(value: progressFraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            } else if toast.kind == .download && toast.status == .pending {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }

            toastActions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: notificationCornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)

                BrowserChromeBackground(
                    bezelStyle: bezelStyle,
                    cornerRadius: notificationCornerRadius,
                    effect: .liquidGlass(
                        style: .clear,
                        tintColor: NSColor.black.withAlphaComponent(0.18)
                    ),
                    profileColor: profileColor,
                    profileTintAlpha: 0.24
                )
            }
            .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: notificationCornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
        }
        .overlay(alignment: .topLeading) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.86))
                    .frame(width: 18, height: 18)
                    .background {
                        ZStack {
                            Circle()
                                .fill(.ultraThinMaterial)

                            Circle()
                                .fill(Color.black.opacity(0.28))
                        }
                    }
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.1), lineWidth: 0.6)
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .scaleEffect(isHovered ? 1 : 0.86)
            .offset(x: -2, y: -2)
            .accessibilityLabel("Dismiss")
            .help("Dismiss")
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .shadow(color: Color.black.opacity(0.28), radius: 28, y: 14)
        .offset(x: dragOffset)
        .opacity(max(0.35, 1 - Double(abs(dragOffset) / 180)))
        .onHover { isHovered = $0 }
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    dragOffset = value.translation.width
                }
                .onEnded { value in
                    if abs(value.translation.width) > 96 || abs(value.predictedEndTranslation.width) > 150 {
                        withAnimation(.easeOut(duration: 0.14)) {
                            dragOffset = value.translation.width < 0 ? -420 : 420
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            onDismiss()
                            dragOffset = 0
                        }
                    } else {
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                            dragOffset = 0
                        }
                    }
                }
        )
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var toastActions: some View {
        switch toast.kind {
        case .mediaPermission:
            HStack(spacing: 8) {
                Button("Deny", action: onDeny)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background {
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    }

                Button("Allow", action: onAllow)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .frame(height: 24)
                    .background {
                        Capsule(style: .continuous)
                            .fill(Color.accentColor)
                    }

                Spacer()
            }
            .padding(.leading, 30)
        case .download:
            if toast.status == .success {
                HStack {
                    Button("Open", action: onOpenDownload)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background {
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        }

                    Spacer()
                }
                .padding(.leading, 30)
            }
        }
    }
}

private struct LoadingBezelPill: View {
    @State private var isPulsing = false

    var body: some View {
        Capsule(style: .continuous)
            .fill(Color.white.opacity(isPulsing ? 0.86 : 0.34))
            .frame(width: isPulsing ? 46 : 34, height: 3)
            .shadow(color: Color.white.opacity(isPulsing ? 0.32 : 0.12), radius: 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear {
                isPulsing = true
            }
    }
}

private struct BrowserConsolePanel: View {
    let messages: [BrowserConsoleMessage]
    let bezelStyle: BrowserBezelStyle
    let profileColor: NSColor
    let onCopy: () -> Void
    let onClear: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Console")
                    .font(.system(size: 12, weight: .semibold))

                Spacer()

                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(messages.isEmpty)
                .accessibilityLabel("Copy Console")
                .help("Copy Console")

                Button("Clear", action: onClear)
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(messages.isEmpty)
                    .accessibilityLabel("Clear Console")

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Console")
                .help("Close Console")
            }
            .padding(.horizontal, 12)
            .frame(height: 40)

            Divider()
                .opacity(0.45)

            if messages.isEmpty {
                Text("No console messages")
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(messages) { message in
                                BrowserConsoleRow(message: message)
                                    .id(message.id)
                            }
                        }
                    }
                    .scrollIndicators(.visible)
                    .onChange(of: messages.last?.id) { _, newValue in
                        guard let newValue else {
                            return
                        }

                        proxy.scrollTo(newValue, anchor: .bottom)
                    }
                }
            }
        }
        .background {
            BrowserChromeBackground(
                bezelStyle: bezelStyle,
                cornerRadius: 8,
                effect: .liquidGlass(
                    style: .regular,
                    tintColor: NSColor.black.withAlphaComponent(0.12)
                ),
                profileColor: profileColor
            )
                .shadow(color: .black.opacity(0.22), radius: 24, y: 12)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct BrowserConsoleRow: View {
    let message: BrowserConsoleMessage

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func timeString(for date: Date) -> String {
        timeFormatter.string(from: date)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Self.timeString(for: message.date))
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)

            Text(message.level.uppercased())
                .foregroundStyle(levelColor)
                .frame(width: 48, alignment: .leading)

            Text(message.source)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(message.message)
                    .textSelection(.enabled)
                    .foregroundStyle(.primary)

                if let url = message.url, !url.isEmpty {
                    Text(url)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11, weight: .regular, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(rowBackground)
    }

    private var levelColor: Color {
        switch message.level.lowercased() {
        case "error":
            return .red
        case "warn", "warning":
            return .orange
        case "debug":
            return .blue
        default:
            return .secondary
        }
    }

    private var rowBackground: Color {
        switch message.source {
        case "browser", "diagnostic":
            return Color.accentColor.opacity(0.08)
        default:
            return Color.clear
        }
    }
}

private struct NewTabPrompt: View {
    @ObservedObject var browser: BrowserState

    let bezelStyle: BrowserBezelStyle
    let initialAddressText: String
    let selectsInitialText: Bool
    let suggestionMode: NewTabPromptSuggestionMode
    let onSubmit: (String) -> Bool
    let onSwitchToTab: (BrowserTab.ID) -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool
    @State private var addressText = ""
    @State private var selectedSuggestionID: String?
    @State private var arrowKeyMonitor: Any?

    private var trimmedAddress: String {
        addressText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var suggestions: [NewTabPromptSuggestion] {
        let query = trimmedAddress.lowercased()
        let openTabs = browser.tabs
            .filter { tab in
                guard tab.url != nil, tab.id != browser.selectedTabID else {
                    return false
                }

                return query.isEmpty || Self.matches(query: query, title: tab.displayTitle, urlText: tab.addressText)
            }
            .map(NewTabPromptSuggestion.openTab)

        let openTabURLs = Set(browser.tabs.compactMap { $0.url?.absoluteString })
        let history = browser.historySuggestions
            .filter { suggestion in
                !openTabURLs.contains(suggestion.url.absoluteString)
                    && (query.isEmpty || Self.matches(query: query, title: suggestion.displayTitle, urlText: suggestion.url.absoluteString))
            }
            .map(NewTabPromptSuggestion.history)

        return Array((openTabs + history).prefix(5))
    }

    private var selectedSuggestion: NewTabPromptSuggestion? {
        guard !suggestions.isEmpty else {
            return nil
        }

        if let selectedSuggestionID,
           let suggestion = suggestions.first(where: { $0.id == selectedSuggestionID }) {
            return suggestion
        }

        return suggestions.first
    }

    var body: some View {
        GeometryReader { proxy in
            let paletteWidth = min(max(proxy.size.width * 0.50, 560), 760)

            ZStack {
                Color(nsColor: browser.profileNSColor).opacity(0.24)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onCancel)

                VStack(spacing: 0) {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)

                        TextField("Search or Enter URL...", text: $addressText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 18, weight: .semibold))
                            .lineLimit(1)
                            .focused($isFocused)
                            .onSubmit {
                                submit()
                            }
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 54)

                    if !suggestions.isEmpty {
                        Divider()
                            .overlay(Color.white.opacity(0.08))
                            .padding(.horizontal, 12)

                        VStack(spacing: 3) {
                            ForEach(suggestions, id: \.id) { suggestion in
                                NewTabPromptSuggestionRow(
                                    suggestion: suggestion,
                                    isSelected: suggestion.id == (selectedSuggestionID ?? suggestions.first?.id),
                                    mode: suggestionMode,
                                    onHighlight: {
                                        selectedSuggestionID = suggestion.id
                                    },
                                    onSelect: {
                                        selectedSuggestionID = suggestion.id
                                        activate(suggestion)
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
                .frame(width: paletteWidth)
                .background {
                    BrowserChromeBackground(
                        bezelStyle: bezelStyle,
                        cornerRadius: 10,
                        effect: .liquidGlass(
                            style: .regular,
                            tintColor: NSColor.black.withAlphaComponent(0.12)
                        ),
                        profileColor: browser.profileNSColor
                    )
                        .shadow(color: .black.opacity(0.22), radius: 14, y: 7)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(isFocused ? 0.28 : 0.16), lineWidth: 1)
                }
                .padding(.horizontal, 16)
                .onTapGesture {}
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onChange(of: addressText) { _, _ in
            selectedSuggestionID = suggestions.first?.id
        }
        .onChange(of: suggestions.map(\.id)) { _, ids in
            if let selectedSuggestionID, ids.contains(selectedSuggestionID) {
                return
            }

            selectedSuggestionID = ids.first
        }
        .onMoveCommand { direction in
            moveSelection(direction)
        }
        .onAppear {
            addressText = initialAddressText
            DispatchQueue.main.async {
                isFocused = true
                if selectsInitialText {
                    selectFocusedText()
                }
                selectedSuggestionID = suggestions.first?.id
            }
            installArrowKeyMonitorIfNeeded()
        }
        .onDisappear {
            removeArrowKeyMonitor()
        }
        .onExitCommand(perform: onCancel)
    }

    private func submit() {
        let address = trimmedAddress

        guard !address.isEmpty else {
            return
        }

        if let selectedSuggestion {
            activate(selectedSuggestion)
            return
        }

        if onSubmit(address) {
            addressText = ""
        }
    }

    private func activate(_ suggestion: NewTabPromptSuggestion) {
        switch suggestion {
        case .openTab(let tab):
            onSwitchToTab(tab.id)
        case .history(let historySuggestion):
            if onSubmit(historySuggestion.url.absoluteString) {
                addressText = ""
            }
        }
    }

    private func selectFocusedText() {
        DispatchQueue.main.async {
            (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !suggestions.isEmpty else {
            selectedSuggestionID = nil
            return
        }

        let currentID = selectedSuggestionID ?? suggestions.first?.id
        let currentIndex = currentID.flatMap { id in
            suggestions.firstIndex { $0.id == id }
        } ?? 0

        switch direction {
        case .down:
            selectedSuggestionID = suggestions[(currentIndex + 1) % suggestions.count].id
        case .up:
            selectedSuggestionID = suggestions[(currentIndex - 1 + suggestions.count) % suggestions.count].id
        default:
            break
        }
    }

    private func installArrowKeyMonitorIfNeeded() {
        guard arrowKeyMonitor == nil else {
            return
        }

        arrowKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else {
                return event
            }

            switch event.keyCode {
            case 125:
                moveSelection(.down)
                return nil
            case 126:
                moveSelection(.up)
                return nil
            default:
                return event
            }
        }
    }

    private func removeArrowKeyMonitor() {
        guard let arrowKeyMonitor else {
            return
        }

        NSEvent.removeMonitor(arrowKeyMonitor)
        self.arrowKeyMonitor = nil
    }

    private static func matches(query: String, title: String, urlText: String) -> Bool {
        title.lowercased().contains(query) || urlText.lowercased().contains(query)
    }
}

@MainActor
private enum NewTabPromptSuggestionMode {
    case openNewTab
    case navigate
}

@MainActor
private enum NewTabPromptSuggestion {
    case openTab(BrowserTab)
    case history(BrowserHistorySuggestion)

    var id: String {
        switch self {
        case .openTab(let tab):
            return "tab-\(tab.id.uuidString)"
        case .history(let suggestion):
            return "history-\(suggestion.id)"
        }
    }

    var title: String {
        switch self {
        case .openTab(let tab):
            return tab.displayTitle
        case .history(let suggestion):
            return suggestion.displayTitle
        }
    }

    var subtitle: String {
        switch self {
        case .openTab(let tab):
            return tab.addressText
        case .history(let suggestion):
            return suggestion.url.absoluteString
        }
    }

    func actionTitle(mode: NewTabPromptSuggestionMode) -> String? {
        if mode == .navigate {
            return "Navigate"
        }

        switch self {
        case .openTab:
            return "Switch to Tab"
        case .history:
            return nil
        }
    }

    func actionIconName(mode: NewTabPromptSuggestionMode) -> String {
        if mode == .navigate {
            return "arrow.forward"
        }

        switch self {
        case .openTab:
            return "arrow.right"
        case .history:
            return "clock.arrow.circlepath"
        }
    }
}

private struct NewTabPromptSuggestionRow: View {
    let suggestion: NewTabPromptSuggestion
    let isSelected: Bool
    let mode: NewTabPromptSuggestionMode
    let onHighlight: () -> Void
    let onSelect: () -> Void

    var body: some View {
        Button {
            onHighlight()
            onSelect()
        } label: {
            HStack(spacing: 9) {
                NewTabPromptSuggestionIcon(suggestion: suggestion, isSelected: isSelected)

                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if !suggestion.subtitle.isEmpty {
                        Text(suggestion.subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let actionTitle = suggestion.actionTitle(mode: mode) {
                    Text(actionTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                }

                Image(systemName: suggestion.actionIconName(mode: mode))
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSelected ? Color.white.opacity(0.92) : Color.primary.opacity(0.08))
                    }
                    .foregroundStyle(isSelected ? Color.black.opacity(0.72) : Color.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 50)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.24) : Color.clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovered in
            if isHovered {
                onHighlight()
            }
        }
    }
}

private struct NewTabPromptSuggestionIcon: View {
    let suggestion: NewTabPromptSuggestion
    let isSelected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.9) : Color.primary.opacity(0.08))

            switch suggestion {
            case .openTab(let tab):
                if let favicon = tab.favicon {
                    Image(nsImage: favicon)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isSelected ? Color.black.opacity(0.65) : Color.secondary)
                }
            case .history(let suggestion):
                if let favicon = suggestion.favicon {
                    Image(nsImage: favicon)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isSelected ? Color.black.opacity(0.65) : Color.secondary)
                }
            }
        }
        .frame(width: 32, height: 32)
    }
}
