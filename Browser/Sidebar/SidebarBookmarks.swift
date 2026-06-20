import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

struct BookmarkShelf: View {
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
