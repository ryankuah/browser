import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SidebarTabList: View {
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

struct BrowserTabIcon: View {
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
