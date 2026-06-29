import AppKit
import SwiftUI

struct BrowserSidebar: View {
    @ObservedObject var browser: BrowserState
    @ObservedObject var updateController: BrowserUpdateController
    @Binding var isSettingsPresented: Bool
    let window: NSWindow?
    let cornerRadius: CGFloat
    let onOpenFullSettings: () -> Void
    let onOpenAddressPrompt: () -> Void
    let onOpenHistory: () -> Void
    let onOpenMail: () -> Void
    let onOpenCalendar: () -> Void

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
                updateController: updateController,
                isPresented: $isDownloadsPresented,
                isSettingsPresented: $isSettingsPresented,
                onOpenFullSettings: onOpenFullSettings,
                onOpenHistory: onOpenHistory,
                onOpenMail: onOpenMail,
                onOpenCalendar: onOpenCalendar
            )
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            BrowserChromeBackground(
                bezelStyle: browser.bezelStyle,
                cornerRadius: cornerRadius,
                maskedCorners: [
                    .layerMinXMinYCorner,
                    .layerMinXMaxYCorner
                ],
                effect: .liquidGlass(
                    style: .regular,
                    tintColor: NSColor.black.withAlphaComponent(0.06)
                ),
                profileColor: browser.profileNSColor
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
        .onDisappear {
            isDownloadsPresented = false
            isSettingsPresented = false
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
            tab: browser.activeTab,
            onOpenAddressPrompt: onOpenAddressPrompt
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

struct SidebarIconButton: View {
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
