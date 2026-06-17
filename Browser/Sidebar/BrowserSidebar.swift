import AppKit
import SwiftUI

struct BrowserSidebar: View {
    @ObservedObject var browser: BrowserState
    let window: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                TrafficLightControls(window: window)

                if let activeTab = browser.activeTab {
                    SidebarIconButton(systemName: "chevron.left", label: "Back") {
                        browser.goBack()
                    }
                    .disabled(!activeTab.canGoBack)

                    SidebarIconButton(systemName: "chevron.right", label: "Forward") {
                        browser.goForward()
                    }
                    .disabled(!activeTab.canGoForward)

                    SidebarIconButton(
                        systemName: activeTab.isLoading ? "xmark" : "arrow.clockwise",
                        label: activeTab.isLoading ? "Stop" : "Reload"
                    ) {
                        browser.reloadOrStop()
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            if let activeTab = browser.activeTab {
                BrowserControls(
                    browser: browser,
                    tab: activeTab
                )
                .id(activeTab.id)
            }

            Divider()
                .padding(.horizontal, 16)

            HStack {
                Text("Tabs")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Spacer()

                SidebarIconButton(systemName: "plus", label: "New Tab") {
                    browser.newTab()
                }
            }
            .padding(.horizontal, 16)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(browser.tabs) { tab in
                        BrowserTabRow(
                            tab: tab,
                            isSelected: browser.selectedTabID == tab.id,
                            onSelect: {
                                browser.selectTab(id: tab.id)
                            },
                            onClose: {
                                browser.closeTab(id: tab.id)
                            }
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            LiquidGlassView(
                style: .regular,
                cornerRadius: 0,
                tintColor: NSColor.black.withAlphaComponent(0.06)
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
}

private struct BrowserControls: View {
    @ObservedObject var browser: BrowserState
    @ObservedObject var tab: BrowserTab

    var body: some View {
        BrowserAddressField(
            tab: tab,
            onSubmit: browser.loadAddress
        )
        .padding(.horizontal, 16)
    }
}

private struct BrowserAddressField: View {
    @ObservedObject var tab: BrowserTab

    let onSubmit: (String) -> Void

    @FocusState private var isFocused: Bool
    @State private var addressText = ""

    var body: some View {
        TextField("Search or enter website", text: $addressText)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .regular))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.primary.opacity(0.06))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isFocused ? Color.accentColor.opacity(0.65) : Color.secondary.opacity(0.22), lineWidth: 1)
            }
            .focused($isFocused)
            .onSubmit {
                onSubmit(addressText)
                isFocused = false
            }
            .onAppear {
                addressText = tab.addressText
            }
            .onChange(of: isFocused) { _, newValue in
                if newValue {
                    addressText = tab.addressText
                }
            }
            .onChange(of: tab.addressText) { _, newValue in
                guard !isFocused else {
                    return
                }

                addressText = newValue
            }
    }
}

private struct BrowserTabRow: View {
    @ObservedObject var tab: BrowserTab

    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.16))

                if tab.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(tab.displayTitle)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(tab.displaySubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isSelected ? 1 : 0.68)
            .accessibilityLabel("Close Tab")
        }
        .padding(.horizontal, 8)
        .frame(height: 42)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.09) : Color.clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture(perform: onSelect)
        .accessibilityLabel(tab.displayTitle)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Select Tab", onSelect)
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
        .onHover { isHovered = $0 }
        .accessibilityLabel(label)
        .help(label)
    }
}
