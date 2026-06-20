import AppKit
import SwiftUI

struct BrowserConsolePanel: View {
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

struct BrowserConsoleRow: View {
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
