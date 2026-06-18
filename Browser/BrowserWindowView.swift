import AppKit
import SwiftUI

struct BrowserWindowView: View {
    @StateObject private var browser = BrowserState()
    @StateObject private var windowReference = WindowReference()

    @State private var isLeftZoneHovered = false
    @State private var isSidebarHovered = false
    @State private var isNewTabPromptPresented = false
    @State private var isConsolePresented = false
    @State private var isSettingsPresented = false
    @State private var commandKeyMonitor: Any?
    @State private var pendingSidebarClose: DispatchWorkItem?

    private let topChromeHeight: CGFloat = 6
    private let sidebarHoverWidth: CGFloat = 6
    private let contentInset: CGFloat = 6
    private let sidebarWidth: CGFloat = 236
    private let sidebarCloseDelay: TimeInterval = 0.1
    private let shellCornerRadius: CGFloat = 20
    private var webCornerRadius: CGFloat {
        max(shellCornerRadius - contentInset, 0)
    }

    private var preferredColorScheme: ColorScheme? {
        browser.bezelStyle == .simple ? .dark : nil
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
                    effect: .liquidGlass(style: .clear)
                )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false)

                ZStack(alignment: .topLeading) {
                    if let activeTab = browser.activeTab, browser.shouldMountWebView(for: activeTab) {
                        WebView(
                            webView: activeTab.webView,
                            cornerRadius: webCornerRadius,
                            blockedHitTestWidth: isSidebarVisible ? sidebarOverlayWidth : 0,
                            onMount: {
                                browser.webViewDidMount(for: activeTab.id)
                            }
                        )
                        .id(activeTab.id)
                    }

                    if isSidebarVisible {
                        BrowserSidebar(
                            browser: browser,
                            isSettingsPresented: $isSettingsPresented,
                            window: windowReference.window
                        )
                            .frame(width: sidebarOverlayWidth, height: webSize.height, alignment: .topLeading)
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
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(2)
                }

                if isConsolePresented {
                    BrowserConsolePanel(
                        messages: browser.consoleMessages,
                        bezelStyle: browser.bezelStyle,
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
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(4)
                }

                BrowserToastStack(browser: browser)
                    .frame(width: min(max(proxy.size.width - 32, 0), 360), alignment: .topLeading)
                    .offset(x: webOrigin.x + 12, y: webOrigin.y + 12)
                    .zIndex(5)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .ignoresSafeArea()
            .animation(.easeOut(duration: 0.12), value: isNewTabPromptPresented)
            .animation(.easeInOut(duration: 0.16), value: isSettingsPresented)
            .animation(.easeInOut(duration: 0.16), value: isConsolePresented)
            .animation(.easeInOut(duration: 0.16), value: browser.bezelStyle)
            .animation(.spring(response: 0.24, dampingFraction: 0.86), value: browser.toasts)
            .animation(.easeInOut(duration: 0.16), value: browser.isElementFullscreenActive)
        }
        .ignoresSafeArea()
        .preferredColorScheme(preferredColorScheme)
        .background(
            WindowAccessor { window in
                WindowAccessor.configureBrowserWindow(window, bezelStyle: browser.bezelStyle)
                windowReference.update(window)
            }
        )
        .focusedSceneValue(\.browserCommandActions, BrowserCommandActions(
            newTab: {
                isNewTabPromptPresented = true
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

private struct BrowserToastStack: View {
    @ObservedObject var browser: BrowserState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(browser.toasts.prefix(4)) { toast in
                BrowserToastView(
                    toast: toast,
                    bezelStyle: browser.bezelStyle,
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
                .transition(.asymmetric(
                    insertion: .move(edge: .leading).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .allowsHitTesting(!browser.toasts.isEmpty)
    }
}

private struct BrowserToastView: View {
    let toast: BrowserToast
    let bezelStyle: BrowserBezelStyle
    let onAllow: () -> Void
    let onDeny: () -> Void
    let onOpenDownload: () -> Void
    let onDismiss: () -> Void

    @State private var dragOffset: CGFloat = 0

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
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: toast.iconSystemName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(toast.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(toast.message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
                .help("Dismiss")
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
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background {
            BrowserChromeBackground(
                bezelStyle: bezelStyle,
                cornerRadius: 14,
                effect: .liquidGlass(
                    style: .regular,
                    tintColor: NSColor.white.withAlphaComponent(0.08)
                )
            )
            .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.22), radius: 20, y: 10)
        .offset(x: dragOffset)
        .opacity(max(0.35, 1 - Double(abs(dragOffset) / 180)))
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
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background {
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    }

                Button("Allow", action: onAllow)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background {
                        Capsule(style: .continuous)
                            .fill(Color.accentColor)
                    }

                Spacer()
            }
            .padding(.leading, 34)
        case .download:
            if toast.status == .success {
                HStack {
                    Button("Open", action: onOpenDownload)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background {
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        }

                    Spacer()
                }
                .padding(.leading, 34)
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
                effect: .material
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
    let onSubmit: (String) -> Bool
    let onSwitchToTab: (BrowserTab.ID) -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool
    @State private var addressText = ""
    @State private var selectedSuggestionID: String?

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
                Color.black.opacity(0.18)
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
                                    onSelect: {
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
                        effect: .material
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
            DispatchQueue.main.async {
                isFocused = true
                selectedSuggestionID = suggestions.first?.id
            }
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

    private static func matches(query: String, title: String, urlText: String) -> Bool {
        title.lowercased().contains(query) || urlText.lowercased().contains(query)
    }
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

    var actionTitle: String? {
        switch self {
        case .openTab:
            return "Switch to Tab"
        case .history:
            return nil
        }
    }

    var actionIconName: String {
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
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
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

                if let actionTitle = suggestion.actionTitle {
                    Text(actionTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                }

                Image(systemName: suggestion.actionIconName)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSelected ? Color.white.opacity(0.92) : Color.primary.opacity(0.08))
                    }
                    .foregroundStyle(isSelected ? Color.black.opacity(0.72) : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .frame(height: 50)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.24) : Color.clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
