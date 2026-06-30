import AppKit
import SwiftUI

struct BrowserMailPage: View {
    @ObservedObject var browser: BrowserState
    @ObservedObject var session: BrowserSessionController
    let onClose: () -> Void

    @State private var selectedMessageID: BrowserMailMessage.ID?
    @State private var query = ""

    private var filteredMessages: [BrowserMailMessage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            return session.mailMessages
        }

        return session.mailMessages.filter { message in
            [message.from, message.to, message.subject, message.snippet]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(trimmed) }
        }
    }

    private var selectedMessage: BrowserMailMessage? {
        if let selectedMessageID,
           let message = filteredMessages.first(where: { $0.id == selectedMessageID }) {
            return message
        }

        return filteredMessages.first
    }

    private var primaryBackfillState: BrowserMailBackfillState? {
        if let accountID = session.googleAccounts.first?.id {
            return session.mailBackfillStates.first { $0.googleAccountId == accountID }
        }
        return session.mailBackfillStates.first
    }

    private var backfillStatusText: String? {
        guard let state = primaryBackfillState else {
            return nil
        }

        switch state.status {
        case "queued":
            return "Backfill queued"
        case "running":
            return "Backfilling \(state.importedCount)"
        case "done":
            return state.importedCount > 0 ? "Backfilled \(state.importedCount)" : "Backfill complete"
        case "failed":
            return "Backfill failed"
        default:
            return nil
        }
    }

    var body: some View {
        ZStack {
            BrowserChromeBackground(
                bezelStyle: browser.bezelStyle,
                cornerRadius: 0,
                effect: .liquidGlass(style: .regular, tintColor: NSColor.black.withAlphaComponent(0.16)),
                profileColor: browser.profileNSColor
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                Divider()
                    .opacity(0.45)

                if session.mailMessages.isEmpty {
                    emptyState
                } else {
                    mailContent
                }
            }
        }
        .onAppear {
            session.refreshCloudData()
            if selectedMessageID == nil {
                selectedMessageID = filteredMessages.first?.id
            }
        }
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Mail")

            Image(systemName: "envelope")
                .font(.system(size: 15, weight: .semibold))

            Text("Mail")
                .font(.system(size: 15, weight: .semibold))

            Text("\(session.mailMessages.count)")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            if let backfillStatusText {
                Text(backfillStatusText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            TextField("Search mail", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .frame(width: 240, height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                }

            Button {
                session.refreshCloudData()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .help("Refresh")

            if session.hasConnectedGoogleAccount {
                Button {
                    session.startGmailBackfill()
                } label: {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(primaryBackfillState?.isRunning == true)
                .help("Backfill recent Gmail")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("No Imported Mail")
                .font(.system(size: 15, weight: .semibold))

            Text(emptyStateMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            if session.hasConnectedGoogleAccount {
                HStack(spacing: 10) {
                    Button {
                        session.refreshCloudData()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        session.startGmailBackfill()
                    } label: {
                        Label(primaryBackfillState?.isRunning == true ? "Backfilling" : "Backfill Mail", systemImage: "tray.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(primaryBackfillState?.isRunning == true)
                }
            } else {
                Button {
                    session.openGoogleConnectionURL()
                } label: {
                    Label("Connect Google", systemImage: "link")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateMessage: String {
        if let account = session.googleAccounts.first {
            return "Google is connected as \(account.email). Mail may still be importing, or Gmail returned no recent messages."
        }

        return "Connect Google to import Gmail messages and attachments into Convex. Google remains read-only."
    }

    private var mailContent: some View {
        HStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredMessages) { message in
                        MailMessageRow(
                            message: message,
                            isSelected: selectedMessage?.id == message.id
                        ) {
                            selectedMessageID = message.id
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(width: 340)

            Divider()
                .opacity(0.45)

            if let selectedMessage {
                MailMessageDetail(message: selectedMessage)
            } else {
                emptySearchState
            }
        }
    }

    private var emptySearchState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("No Matches")
                .font(.system(size: 14, weight: .semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MailMessageRow: View {
    let message: BrowserMailMessage
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(message.from ?? "Unknown sender")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)

                    Spacer()

                    if let displayDate = message.displayDate {
                        Text(displayDate, style: .date)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(message.subject ?? "No subject")
                    .font(.system(size: 12))
                    .lineLimit(1)

                Text(message.snippet ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.primary.opacity(0.1) : Color.clear)
        }
        .buttonStyle(.plain)
    }
}

private struct MailMessageDetail: View {
    let message: BrowserMailMessage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message.subject ?? "No subject")
                        .font(.system(size: 20, weight: .semibold))
                        .textSelection(.enabled)

                    VStack(alignment: .leading, spacing: 4) {
                        headerLine("From", message.from)
                        headerLine("To", message.to)
                        if let date = message.displayDate {
                            headerLine("Date", DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short))
                        }
                    }
                    .font(.system(size: 12))
                }

                Divider()
                    .opacity(0.45)

                Text(message.bodyText ?? message.snippet ?? "No body imported for this message.")
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func headerLine(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
            Text(value ?? "-")
                .textSelection(.enabled)
        }
    }
}
