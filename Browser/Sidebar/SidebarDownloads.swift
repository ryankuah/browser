import AppKit
import SwiftUI

struct DownloadsFooter: View {
    @ObservedObject var browser: BrowserState
    @ObservedObject var updateController: BrowserUpdateController
    @Binding var isPresented: Bool
    @Binding var isSettingsPresented: Bool
    let onOpenFullSettings: () -> Void
    let onOpenHistory: () -> Void

    private var activeDownloadCount: Int {
        browser.downloads.filter { $0.status == .inProgress }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isPresented {
                DownloadsPanel(
                    browser: browser,
                    bezelStyle: browser.bezelStyle,
                    profileColor: browser.profileNSColor
                )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if isSettingsPresented {
                BrowserSettingsPanel(
                    browser: browser,
                    bezelStyle: browser.bezelStyle,
                    profileColor: browser.profileNSColor,
                    onOpenFullSettings: onOpenFullSettings
                )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack {
                Spacer()

                if updateController.isUpdateButtonVisible {
                    SidebarIconButton(
                        systemName: updateController.updateButtonIconSystemName,
                        label: updateController.updateButtonHelp
                    ) {
                        updateController.performUpdateButtonAction()
                    }
                    .disabled(updateController.state == .downloading || updateController.state == .extracting || updateController.state == .installing)
                    .transition(.scale(scale: 0.82).combined(with: .opacity))
                }

                SidebarIconButton(
                    systemName: "clock.arrow.circlepath",
                    label: "History"
                ) {
                    onOpenHistory()
                }

                DownloadsIconButton(
                    activeDownloadCount: activeDownloadCount,
                    isPresented: isPresented
                ) {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        if !isPresented {
                            isSettingsPresented = false
                        }
                        isPresented.toggle()
                    }
                }

                SidebarIconButton(
                    systemName: isSettingsPresented ? "gearshape.fill" : "gearshape",
                    label: "Settings"
                ) {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        if !isSettingsPresented {
                            isPresented = false
                        }
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

private struct DownloadsPanel: View {
    @ObservedObject var browser: BrowserState
    let bezelStyle: BrowserBezelStyle
    let profileColor: NSColor

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
                            DownloadRow(
                                download: download,
                                onOpen: {
                                    browser.openDownloadedFile(download)
                                },
                                onShowInFinder: {
                                    browser.showDownloadInFinder(download)
                                },
                                onCopyFilePath: {
                                    browser.copyDownloadFilePath(download)
                                },
                                onCopySourceURL: {
                                    browser.copyDownloadSourceURL(download)
                                },
                                onCancel: {
                                    browser.cancelDownload(id: download.id)
                                },
                                onRetry: {
                                    browser.retryDownload(id: download.id)
                                }
                            )
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
                effect: .liquidGlass(
                    style: .regular,
                    tintColor: NSColor.black.withAlphaComponent(0.12)
                ),
                profileColor: profileColor
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
    let onShowInFinder: () -> Void
    let onCopyFilePath: () -> Void
    let onCopySourceURL: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void

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
        .contextMenu {
            if download.canCancel {
                Button("Cancel", action: onCancel)
                Divider()
            }

            if download.canRetry {
                Button("Retry", action: onRetry)
                Divider()
            }

            Button("Open") {
                onOpen()
            }
            .disabled(download.status != .finished || download.destinationURL == nil)

            Button("Show in Finder") {
                onShowInFinder()
            }
            .disabled(download.destinationURL == nil)

            Divider()

            Button("Copy File Path") {
                onCopyFilePath()
            }
            .disabled(download.destinationURL == nil)

            Button("Copy Source URL") {
                onCopySourceURL()
            }
            .disabled(download.sourceURL == nil)
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
