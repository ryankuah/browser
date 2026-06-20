import AppKit
import SwiftUI

struct BrowserFindNavigationRequest: Equatable {
    let id = UUID()
    let backwards: Bool
}

struct BrowserFindPanel: View {
    @ObservedObject var browser: BrowserState
    let navigationRequest: BrowserFindNavigationRequest?
    let bezelStyle: BrowserBezelStyle
    let profileColor: NSColor
    let onClose: () -> Void

    @FocusState private var isFocused: Bool
    @State private var query = ""
    @State private var isNoMatch = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("Find", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .focused($isFocused)
                .onSubmit {
                    performFind(backwards: false)
                }

            if isNoMatch {
                Text("No match")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            BrowserFindButton(systemName: "chevron.up", label: "Previous") {
                performFind(backwards: true)
            }
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            BrowserFindButton(systemName: "chevron.down", label: "Next") {
                performFind(backwards: false)
            }
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            BrowserFindButton(systemName: "xmark", label: "Close", action: onClose)
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background {
            BrowserChromeBackground(
                bezelStyle: bezelStyle,
                cornerRadius: 10,
                effect: .liquidGlass(
                    style: .regular,
                    tintColor: NSColor.black.withAlphaComponent(0.12)
                ),
                profileColor: profileColor
            )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.2), radius: 20, y: 10)
        .onAppear {
            DispatchQueue.main.async {
                isFocused = true
            }
        }
        .onChange(of: query) { _, _ in
            performFind(backwards: false)
        }
        .onChange(of: navigationRequest?.id) { _, _ in
            guard let navigationRequest else {
                return
            }

            performFind(backwards: navigationRequest.backwards)
        }
        .onExitCommand(perform: onClose)
    }

    private func performFind(backwards: Bool) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            isNoMatch = false
            browser.clearActiveFindSelection()
            return
        }

        browser.findInActivePage(trimmedQuery, backwards: backwards) { found in
            isNoMatch = !found
        }
    }
}

private struct BrowserFindButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
        }
        .onHover { isHovered = $0 }
        .accessibilityLabel(label)
        .help(label)
    }
}
