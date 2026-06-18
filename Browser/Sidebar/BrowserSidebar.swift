import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BrowserSidebar: View {
    @ObservedObject var browser: BrowserState
    @Binding var isSettingsPresented: Bool
    let window: NSWindow?

    @State private var isDownloadsPresented = false
    @State private var draggedTabID: BrowserTab.ID?
    @State private var dimmedTabID: BrowserTab.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerControls
            activePageControls
            bookmarkSection

            SidebarTabList(
                browser: browser,
                draggedTabID: $draggedTabID,
                dimmedTabID: $dimmedTabID
            )

            DownloadsFooter(
                browser: browser,
                isPresented: $isDownloadsPresented,
                isSettingsPresented: $isSettingsPresented
            )
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            BrowserChromeBackground(
                bezelStyle: browser.bezelStyle,
                cornerRadius: 0,
                effect: .liquidGlass(
                    style: .regular,
                    tintColor: NSColor.black.withAlphaComponent(0.06)
                )
            )
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(.white.opacity(0.18))
                .frame(width: 1)
                .allowsHitTesting(false)
        }
    }

    private var headerControls: some View {
        HStack(spacing: 8) {
            TrafficLightControls(window: window)

            SidebarIconButton(systemName: "chevron.left", label: "Back") {
                browser.goBack()
            }
            .disabled(!(browser.activeTab?.canGoBack ?? false))

            SidebarIconButton(systemName: "chevron.right", label: "Forward") {
                browser.goForward()
            }
            .disabled(!(browser.activeTab?.canGoForward ?? false))

            SidebarIconButton(
                systemName: browser.activeTab?.isLoading == true ? "xmark" : "arrow.clockwise",
                label: browser.activeTab?.isLoading == true ? "Stop" : "Reload"
            ) {
                browser.reloadOrStop()
            }
            .disabled(browser.activeTab == nil)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    @ViewBuilder
    private var activePageControls: some View {
        BrowserControls(
            browser: browser,
            tab: browser.activeTab
        )
        .id(browser.activeTab?.id)
    }

    @ViewBuilder
    private var bookmarkSection: some View {
        if !browser.bookmarks.isEmpty || draggedTabID != nil {
            BookmarkShelf(
                browser: browser,
                draggedTabID: $draggedTabID,
                dimmedTabID: $dimmedTabID
            )
            .padding(.horizontal, 10)
        }
    }
}

private struct SidebarTabList: View {
    @ObservedObject var browser: BrowserState
    @Binding var draggedTabID: BrowserTab.ID?
    @Binding var dimmedTabID: BrowserTab.ID?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 5) {
                ForEach(browser.visibleTabs) { tab in
                    BrowserTabRow(
                        tab: tab,
                        isSelected: browser.selectedTabID == tab.id,
                        isBookmarked: browser.isTabBookmarked(id: tab.id),
                        onSelect: {
                            browser.selectTab(id: tab.id)
                        },
                        onBookmark: {
                            browser.bookmarkTab(id: tab.id)
                        },
                        onUnpin: {
                            browser.unpinTab(id: tab.id)
                        },
                        onClose: {
                            browser.closeTab(id: tab.id)
                        }
                    )
                    .opacity(dimmedTabID == tab.id ? 0.45 : 1)
                    .onDrag {
                        draggedTabID = tab.id
                        dimmedTabID = tab.id
                        return NSItemProvider(object: tab.id.uuidString as NSString)
                    }
                    .onDrop(
                        of: [.plainText],
                        delegate: SidebarTabDropDelegate(
                            browser: browser,
                            targetTabID: tab.id,
                            draggedTabID: $draggedTabID,
                            dimmedTabID: $dimmedTabID
                        )
                    )
                }

                TabListEndDropTarget(
                    browser: browser,
                    draggedTabID: $draggedTabID,
                    dimmedTabID: $dimmedTabID
                )
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)
        }
        .scrollIndicators(.hidden)
    }
}

private struct DownloadsFooter: View {
    @ObservedObject var browser: BrowserState
    @Binding var isPresented: Bool
    @Binding var isSettingsPresented: Bool

    private var activeDownloadCount: Int {
        browser.downloads.filter { $0.status == .inProgress }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isPresented {
                DownloadsPanel(
                    browser: browser,
                    bezelStyle: browser.bezelStyle
                )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if isSettingsPresented {
                BrowserSettingsPanel(
                    browser: browser,
                    bezelStyle: browser.bezelStyle
                )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack {
                Spacer()

                DownloadsIconButton(
                    activeDownloadCount: activeDownloadCount,
                    isPresented: isPresented
                ) {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        isPresented.toggle()
                    }
                }

                SidebarIconButton(
                    systemName: isSettingsPresented ? "gearshape.fill" : "gearshape",
                    label: "Settings"
                ) {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isSettingsPresented.toggle()
                    }
                }
            }
        }
    }
}

private struct DownloadsIconButton: View {
    let activeDownloadCount: Int
    let isPresented: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: activeDownloadCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isPresented || isHovered ? Color.primary.opacity(0.08) : Color.clear)
        }
        .overlay(alignment: .topTrailing) {
            if activeDownloadCount > 0 {
                Text("\(activeDownloadCount)")
                    .font(.system(size: 9, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .frame(minWidth: 14, minHeight: 14)
                    .background {
                        Capsule()
                            .fill(Color.accentColor.opacity(0.28))
                    }
                    .offset(x: 5, y: -5)
            }
        }
        .onHover { isHovered in
            self.isHovered = isHovered
        }
        .cursor(.pointingHand)
        .accessibilityLabel("Downloads")
        .help("Downloads")
    }
}

private struct BrowserSettingsPanel: View {
    @ObservedObject var browser: BrowserState
    let bezelStyle: BrowserBezelStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.system(size: 12, weight: .semibold))

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()
                .opacity(0.45)

            VStack(alignment: .leading, spacing: 10) {
                SettingsRow(title: "Search Engine", value: "Google")
                SettingsRow(title: "Downloads", value: "~/Downloads")
                SettingsRow(title: "User Agent", value: "Safari Desktop")
                SettingsRow(title: "JavaScript", value: "Allowed")

                Divider()
                    .opacity(0.38)

                VStack(alignment: .leading, spacing: 7) {
                    Text("Bezel Style")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        ForEach(BrowserBezelStyle.allCases, id: \.rawValue) { style in
                            SettingsSegmentButton(
                                title: style.label,
                                isSelected: browser.bezelStyle == style
                            ) {
                                browser.setBezelStyle(style)
                            }
                        }
                    }
                }

                Divider()
                    .opacity(0.38)

                HStack(spacing: 8) {
                    ForEach(BrowserMediaDeviceKind.allCases, id: \.rawValue) { kind in
                        MediaPermissionButton(
                            kind: kind,
                            isAllowed: browser.activeMediaPermissionSnapshot.isAllowed(kind),
                            isEnabled: browser.activeMediaPermissionSnapshot.hasActivePage
                        ) {
                            browser.toggleActivePageMediaPermission(kind)
                        }
                    }

                    Spacer()
                }
            }
            .padding(10)
        }
        .background {
            BrowserChromeBackground(
                bezelStyle: bezelStyle,
                cornerRadius: 8,
                effect: .material
            )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct SettingsRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)

            Spacer()

            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct SettingsSegmentButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.12) : isHovered ? Color.primary.opacity(0.07) : Color.clear)
        }
        .onHover { isHovered = $0 }
        .cursor(.pointingHand)
        .accessibilityLabel(title)
        .help(title)
    }
}

private struct MediaPermissionButton: View {
    let kind: BrowserMediaDeviceKind
    let isAllowed: Bool
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: kind.iconSystemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .foregroundStyle(isAllowed ? Color.green : Color.secondary)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(backgroundColor)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isAllowed ? Color.green.opacity(0.34) : Color.primary.opacity(0.1), lineWidth: 1)
        }
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovered = $0 }
        .cursor(isEnabled ? .pointingHand : .arrow)
        .accessibilityLabel(kind.accessibilityLabel)
        .help("\(kind.accessibilityLabel): \(isAllowed ? "Allowed" : "Blocked")")
    }

    private var backgroundColor: Color {
        if isAllowed {
            return Color.green.opacity(0.14)
        }

        return isHovered ? Color.primary.opacity(0.07) : Color.primary.opacity(0.04)
    }
}

private struct DownloadsPanel: View {
    @ObservedObject var browser: BrowserState
    let bezelStyle: BrowserBezelStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads")
                    .font(.system(size: 12, weight: .semibold))

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()
                .opacity(0.45)

            if browser.downloads.isEmpty {
                Text("No downloads")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(browser.downloads.prefix(30))) { download in
                            DownloadRow(download: download) {
                                browser.openDownloadedFile(download)
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 240)
                .scrollIndicators(.hidden)
            }
        }
        .background {
            BrowserChromeBackground(
                bezelStyle: bezelStyle,
                cornerRadius: 8,
                effect: .material
            )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct DownloadRow: View {
    let download: BrowserDownload
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(download.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(download.detailText)
                    .font(.system(size: 10))
                    .foregroundStyle(download.status == .failed ? .red : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 7)
        .frame(height: 40)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.07) : Color.clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .cursor(.pointingHand)
        .onHover { isHovered = $0 }
        .onTapGesture {
            onOpen()
        }
        .accessibilityLabel(download.displayName)
        .help(download.status == .finished ? "Open Download" : download.status.label)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch download.status {
        case .inProgress:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.62)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.red)
        }
    }
}

private struct BrowserControls: View {
    @ObservedObject var browser: BrowserState
    var tab: BrowserTab?

    @ViewBuilder
    var body: some View {
        if let tab {
            BrowserAddressField(
                tab: tab,
                onSubmit: browser.loadAddress
            )
            .padding(.horizontal, 10)
        } else {
            EmptyBrowserAddressField(onSubmit: browser.loadAddress)
                .padding(.horizontal, 10)
        }
    }
}

private struct BookmarkDropPreview: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))

                BrowserTabIcon(tab: tab, isSelected: true)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(tab.displayTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(tab.displaySubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        }
    }
}

private struct TabListEndDropTarget: View {
    @ObservedObject var browser: BrowserState
    @Binding var draggedTabID: BrowserTab.ID?
    @Binding var dimmedTabID: BrowserTab.ID?

    @State private var isTargeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(isTargeted ? Color.accentColor.opacity(0.45) : Color.clear)
            .frame(height: draggedTabID == nil ? 2 : 12)
            .onDrop(
                of: [.plainText],
                delegate: SidebarTabDropDelegate(
                    browser: browser,
                    targetTabID: nil,
                    draggedTabID: $draggedTabID,
                    dimmedTabID: $dimmedTabID,
                    isTargeted: $isTargeted
                )
            )
    }
}

@MainActor
private struct BookmarkDropDelegate: DropDelegate {
    let browser: BrowserState
    @Binding var draggedTabID: BrowserTab.ID?
    @Binding var dimmedTabID: BrowserTab.ID?
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        draggedTabID != nil
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedTabID = nil
            dimmedTabID = nil
            isTargeted = false
        }

        guard let draggedTabID else {
            return false
        }

        browser.bookmarkTab(id: draggedTabID)
        return true
    }
}

@MainActor
private struct SidebarTabDropDelegate: DropDelegate {
    let browser: BrowserState
    let targetTabID: BrowserTab.ID?
    @Binding var draggedTabID: BrowserTab.ID?
    @Binding var dimmedTabID: BrowserTab.ID?
    var isTargeted: Binding<Bool> = .constant(false)

    func validateDrop(info: DropInfo) -> Bool {
        draggedTabID != nil
    }

    func dropEntered(info: DropInfo) {
        isTargeted.wrappedValue = true

        guard let draggedTabID,
              draggedTabID != targetTabID else {
            return
        }

        browser.moveVisibleTab(id: draggedTabID, before: targetTabID)
        dimmedTabID = nil
    }

    func dropExited(info: DropInfo) {
        isTargeted.wrappedValue = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedTabID = nil
        dimmedTabID = nil
        isTargeted.wrappedValue = false
        return true
    }
}

private struct BookmarkShelf: View {
    @ObservedObject var browser: BrowserState
    @Binding var draggedTabID: BrowserTab.ID?
    @Binding var dimmedTabID: BrowserTab.ID?

    @State private var isTargeted = false

    private let columnCount = 3

    var body: some View {
        ZStack(alignment: .topLeading) {
            shelfContent
                .opacity(isTargeted ? 0.42 : 1)

            if isTargeted, let draggedTab {
                BookmarkDropPreview(tab: draggedTab)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .padding(.vertical, 2)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isTargeted ? Color.primary.opacity(0.07) : Color.clear)
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.8), lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .animation(.easeInOut(duration: 0.12), value: isTargeted)
        .animation(.easeInOut(duration: 0.12), value: draggedTabID != nil)
        .onDrop(
            of: [.plainText],
            delegate: BookmarkDropDelegate(
                browser: browser,
                draggedTabID: $draggedTabID,
                dimmedTabID: $dimmedTabID,
                isTargeted: $isTargeted
            )
        )
        .accessibilityLabel("Bookmarks")
    }

    @ViewBuilder
    private var shelfContent: some View {
        if browser.bookmarks.isEmpty {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(draggedTabID == nil ? 0 : 0.035))
                .frame(height: draggedTabID == nil ? 0 : 56)
        } else {
            VStack(spacing: 10) {
                ForEach(bookmarkRows.indices, id: \.self) { rowIndex in
                    HStack(spacing: 10) {
                        ForEach(bookmarkRows[rowIndex]) { bookmark in
                            BookmarkButton(
                                bookmark: bookmark,
                                isSelected: browser.isBookmarkActive(id: bookmark.id)
                            ) {
                                browser.openBookmark(id: bookmark.id)
                            } onUnpin: {
                                browser.unpinBookmark(id: bookmark.id)
                            } onCloseTab: {
                                guard let tabID = bookmark.tabID else {
                                    return
                                }

                                browser.closeTab(id: tabID)
                            }
                        }

                        ForEach(0..<emptyCellCount(for: rowIndex), id: \.self) { _ in
                            Color.clear
                                .frame(height: 48)
                        }
                    }
                }
            }
        }
    }

    private var draggedTab: BrowserTab? {
        guard let draggedTabID else {
            return nil
        }

        return browser.tabs.first { $0.id == draggedTabID }
    }

    private var bookmarkRows: [[BrowserBookmark]] {
        stride(from: 0, to: browser.bookmarks.count, by: columnCount).map { startIndex in
            Array(browser.bookmarks[startIndex..<min(startIndex + columnCount, browser.bookmarks.count)])
        }
    }

    private func emptyCellCount(for rowIndex: Int) -> Int {
        guard rowIndex == bookmarkRows.indices.last,
              let lastRow = bookmarkRows.last else {
            return 0
        }

        return columnCount - lastRow.count
    }
}

private struct BookmarkButton: View {
    let bookmark: BrowserBookmark
    let isSelected: Bool
    let action: () -> Void
    let onUnpin: () -> Void
    let onCloseTab: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundColor)

                BookmarkIcon(bookmark: bookmark)
            }
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.red.opacity(0.95) : Color.primary.opacity(isHovered ? 0.12 : 0), lineWidth: isSelected ? 2.5 : 1)
        }
        .onHover { isHovered in
            self.isHovered = isHovered
        }
        .cursor(.pointingHand)
        .contextMenu {
            Button("Unpin", action: onUnpin)

            if bookmark.tabID != nil {
                Divider()

                Button("Close Tab", action: onCloseTab)
            }
        }
        .accessibilityLabel(bookmark.displayTitle)
        .help(bookmark.url.absoluteString)
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.primary.opacity(0.16)
        }

        return isHovered ? Color.primary.opacity(0.1) : Color.primary.opacity(0.07)
    }
}

private struct BookmarkIcon: View {
    let bookmark: BrowserBookmark

    var body: some View {
        if let favicon = bookmark.favicon {
            Image(nsImage: favicon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Image(systemName: "globe")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

private struct BrowserAddressField: View {
    @ObservedObject var tab: BrowserTab

    let onSubmit: (String) -> Void

    @FocusState private var isFocused: Bool
    @State private var addressText = ""

    var body: some View {
        HStack(spacing: 8) {
            if shouldShowOriginIndicator {
                Image(systemName: originSecurityState.iconSystemName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(originIndicatorColor)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel(originSecurityState.accessibilityLabel)
                    .help(originSecurityState.accessibilityLabel)
            }

            TextField("Search or enter website", text: $addressText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular))
                .lineLimit(1)
                .focused($isFocused)
                .cursor(.iBeam)
                .onSubmit {
                    onSubmit(addressText)
                    isFocused = false
                }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.primary.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isFocused ? Color.accentColor.opacity(0.65) : Color.secondary.opacity(0.22), lineWidth: 1)
        }
        .onAppear {
            addressText = tab.displayAddressText
        }
        .onChange(of: isFocused) { _, newValue in
            if newValue {
                addressText = tab.addressText
            } else {
                addressText = tab.displayAddressText
            }
        }
        .onChange(of: tab.addressText) { _, newValue in
            guard !isFocused else {
                return
            }

            addressText = tab.displayAddressText
        }
    }

    private var originSecurityState: OriginSecurityState {
        tab.originSecurityState
    }

    private var shouldShowOriginIndicator: Bool {
        switch originSecurityState {
        case .insecure, .certificateError:
            return true
        case .noPage, .secure, .local:
            return false
        }
    }

    private var originIndicatorColor: Color {
        switch originSecurityState {
        case .noPage:
            return .secondary
        case .secure:
            return .green
        case .local:
            return .blue
        case .insecure, .certificateError:
            return .orange
        }
    }
}

private struct EmptyBrowserAddressField: View {
    let onSubmit: (String) -> Void

    @FocusState private var isFocused: Bool
    @State private var addressText = ""

    var body: some View {
        HStack {
            TextField("Search or enter website", text: $addressText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular))
                .lineLimit(1)
                .focused($isFocused)
                .cursor(.iBeam)
                .onSubmit {
                    onSubmit(addressText)
                    isFocused = false
                    addressText = ""
                }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.primary.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isFocused ? Color.accentColor.opacity(0.65) : Color.secondary.opacity(0.22), lineWidth: 1)
        }
    }
}

private struct BrowserTabRow: View {
    @ObservedObject var tab: BrowserTab

    let isSelected: Bool
    let isBookmarked: Bool
    let onSelect: () -> Void
    let onBookmark: () -> Void
    let onUnpin: () -> Void
    let onClose: () -> Void

    @State private var isCloseHovered = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.16))

                BrowserTabIcon(tab: tab, isSelected: isSelected)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading) {
                Text(tab.displayTitle)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isCloseHovered ? Color.primary.opacity(0.08) : Color.clear)
            }
            .opacity(isSelected ? 1 : 0.68)
            .onHover { isHovered in
                isCloseHovered = isHovered
            }
            .cursor(.pointingHand)
            .accessibilityLabel("Close Tab")
        }
        .padding(.horizontal, 8)
        .frame(height: 42)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tabBackgroundColor)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isHovered ? Color.primary.opacity(0.14) : Color.clear, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { isHovered in
            self.isHovered = isHovered
        }
        .cursor(.pointingHand)
        .onTapGesture(perform: onSelect)
        .contextMenu {
            if isBookmarked {
                Button("Unpin", action: onUnpin)
            } else {
                Button("Bookmark", action: onBookmark)
            }

            Divider()

            Button("Close Tab", action: onClose)
        }
        .accessibilityLabel(tab.displayTitle)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Select Tab", onSelect)
    }

    private var tabBackgroundColor: Color {
        if isSelected {
            return Color.primary.opacity(0.09)
        }

        return isHovered ? Color.primary.opacity(0.045) : Color.clear
    }
}

private struct BrowserTabIcon: View {
    @ObservedObject var tab: BrowserTab

    let isSelected: Bool

    var body: some View {
        if let favicon = tab.favicon {
            Image(nsImage: favicon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
            Image(systemName: "globe")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        }
    }
}

private struct SidebarIconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHovered ? .primary.opacity(0.06) : Color.clear)
        }
        .onHover { isHovered in
            self.isHovered = isHovered
        }
        .cursor(.pointingHand)
        .accessibilityLabel(label)
        .help(label)
    }
}
