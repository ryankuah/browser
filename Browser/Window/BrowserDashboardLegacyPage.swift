import AppKit
import SwiftUI

struct BrowserDashboardLegacyPage: View {
    @ObservedObject var browser: BrowserState
    @ObservedObject var session: BrowserSessionController
    let onClose: () -> Void

    @State private var selectedMessages: [BrowserMailDashboardMessage] = []

    private var dashboard: BrowserMailDashboard? {
        session.mailDashboard
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

                if let dashboard {
                    dashboardContent(dashboard)
                } else {
                    emptyState
                }
            }
        }
        .onAppear {
            session.refreshCloudData()
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
            .help("Close Mail Dashboard")

            Image(systemName: "mail.stack")
                .font(.system(size: 15, weight: .semibold))

            Text("Mail Dashboard")
                .font(.system(size: 15, weight: .semibold))

            Text("\(session.mailMessages.count)")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer()

            if session.hasConnectedGoogleAccount {
                Text(session.googleAccounts.first?.email ?? "Google connected")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Button {
                    session.openGoogleConnectionURL()
                } label: {
                    Label("Connect Google", systemImage: "link")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
            }

            Button {
                session.analyzeRecentMail()
            } label: {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .help("Analyze recent imported mail")

            Button {
                session.refreshCloudData()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("No Mail Analysis Yet")
                .font(.system(size: 15, weight: .semibold))

            Text("Analyze recent imported mail to populate security, notifications, purchases, shipping, subscriptions, invoices, bookings, and events.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            Button {
                session.analyzeRecentMail()
            } label: {
                Label("Analyze Recent Mail", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!session.hasConnectedGoogleAccount)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dashboardContent(_ dashboard: BrowserMailDashboard) -> some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    dashboardSections(dashboard)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Divider()
                .opacity(0.45)

            MailDashboardMessageInspector(
                messages: selectedMessages,
                onOpenMail: {
                    browser.newTab(url: BrowserInternalPage.mail.url)
                }
            )
            .frame(width: 340)
        }
    }

    @ViewBuilder
    private func dashboardSections(_ dashboard: BrowserMailDashboard) -> some View {
        MailDashboardSection(title: "Security Codes", systemImage: "key.horizontal", count: dashboard.securityCodes.count) {
            ForEach(dashboard.securityCodes) { item in
                MailDashboardRow(
                    title: item.serviceName ?? "Security code",
                    detail: item.code,
                    status: "Code",
                    fallbackDate: item.updatedAt,
                    message: item.message,
                    onSelect: { selectedMessages = sourceMessages(item.message) }
                )
            }
        }

        MailDashboardSection(title: "Security Notifications", systemImage: "lock.shield", count: dashboard.securityNotifications.count) {
            ForEach(dashboard.securityNotifications) { item in
                MailDashboardRow(
                    title: item.serviceName ?? securityNotificationTitle(item),
                    detail: securityNotificationDetail(item),
                    status: item.notificationType,
                    fallbackDate: item.updatedAt,
                    message: item.message,
                    onSelect: { selectedMessages = sourceMessages(item.message) }
                )
            }
        }

        MailDashboardSection(title: "Notifications", systemImage: "bell.badge", count: dashboard.notifications.count) {
            ForEach(dashboard.notifications) { item in
                MailDashboardRow(
                    title: item.title ?? item.serviceName ?? "Account notification",
                    detail: notificationDetail(item),
                    status: item.notificationType,
                    fallbackDate: item.updatedAt,
                    message: item.message,
                    onSelect: { selectedMessages = sourceMessages(item.message) }
                )
            }
        }

        MailDashboardSection(title: "Support", systemImage: "lifepreserver", count: dashboard.supportThreads.count) {
            ForEach(dashboard.supportThreads) { item in
                MailDashboardRow(
                    title: item.companyName,
                    detail: [item.ticketId, item.subject].compactMap { $0 }.joined(separator: " · "),
                    status: item.status,
                    fallbackDate: item.updatedAt,
                    message: item.message,
                    onSelect: { selectedMessages = sourceMessages(item.message) }
                )
            }
        }

        MailDashboardSection(title: "Purchases", systemImage: "bag", count: dashboard.orders.count) {
            ForEach(dashboard.orders) { item in
                MailDashboardRow(
                    title: orderTitle(item),
                    detail: orderDetail(item),
                    status: item.status,
                    imageUrl: item.imageUrl,
                    fallbackDate: item.updatedAt,
                    message: item.message,
                    onSelect: { selectedMessages = item.messages.isEmpty ? sourceMessages(item.message) : item.messages }
                )
            }
        }

        MailDashboardSection(title: "Shipping", systemImage: "shippingbox", count: dashboard.shipments.count) {
            ForEach(dashboard.shipments) { item in
                MailDashboardRow(
                    title: shipmentTitle(item),
                    detail: shipmentDetail(item),
                    status: item.status,
                    imageUrl: item.imageUrl,
                    fallbackDate: item.updatedAt,
                    message: item.message,
                    onSelect: { selectedMessages = item.messages?.isEmpty == false ? item.messages ?? [] : sourceMessages(item.message) }
                )
            }
        }

        MailDashboardSection(title: "Subscriptions", systemImage: "repeat", count: dashboard.subscriptions.count) {
            ForEach(dashboard.subscriptions) { item in
                MailDashboardRow(
                    title: item.itemSummary,
                    detail: subscriptionDetail(item),
                    status: item.status,
                    imageUrl: item.imageUrl,
                    preferredDate: item.nextPaymentDueAt,
                    fallbackDate: item.updatedAt,
                    message: item.message,
                    onSelect: { selectedMessages = item.messages.isEmpty ? sourceMessages(item.message) : item.messages }
                )
            }
        }

        MailDashboardSection(title: "Invoices and Payments", systemImage: "doc.text", count: dashboard.invoices.count) {
            ForEach(dashboard.invoices) { item in
                MailDashboardRow(
                    title: item.vendor ?? "Invoice",
                    detail: invoiceDetail(item),
                    status: item.status,
                    fallbackDate: item.updatedAt,
                    message: item.message,
                    onSelect: { selectedMessages = sourceMessages(item.message) }
                )
            }
        }

        MailDashboardSection(title: "Bookings", systemImage: "ticket", count: dashboard.bookings.count) {
            ForEach(dashboard.bookings) { item in
                MailDashboardRow(
                    title: item.title ?? item.provider ?? item.category.capitalized,
                    detail: bookingDetail(item),
                    status: item.category,
                    preferredDate: item.startTime,
                    fallbackDate: item.updatedAt,
                    message: item.message,
                    onSelect: { selectedMessages = sourceMessages(item.message) }
                )
            }
        }

        MailDashboardSection(title: "Meetings & Events", systemImage: "calendar.badge.clock", count: dashboard.meetingsEvents.count) {
            ForEach(dashboard.meetingsEvents) { item in
                MailDashboardRow(
                    title: item.title ?? item.provider ?? "Event",
                    detail: meetingEventDetail(item),
                    status: item.status,
                    preferredDate: item.startTime,
                    fallbackDate: item.updatedAt,
                    message: item.message,
                    onSelect: { selectedMessages = sourceMessages(item.message) }
                )
            }
        }
    }

    private func sourceMessages(_ message: BrowserMailDashboardMessage?) -> [BrowserMailDashboardMessage] {
        message.map { [$0] } ?? []
    }

    private func orderTitle(_ item: BrowserMailOrderSummary) -> String {
        let summary = item.itemSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return summary.isEmpty ? item.merchant : summary
    }

    private func orderDetail(_ item: BrowserMailOrderSummary) -> String {
        [item.merchant, item.orderNumber.map { "Order \($0)" }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func securityNotificationTitle(_ item: BrowserMailSecurityNotification) -> String {
        item.notificationType
            .split(separator: "_")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private func securityNotificationDetail(_ item: BrowserMailSecurityNotification) -> String {
        [item.accountEmail, item.location, item.ipAddress, item.device, item.app, item.url]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func notificationDetail(_ item: BrowserMailNotification) -> String {
        [item.serviceName, item.status == "unknown" ? nil : item.status, item.url]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func bookingDetail(_ item: BrowserMailBookingSummary) -> String {
        let amount = item.amount.map { amount in
            "\(item.currency ?? "") \(amount.formatted(.number.precision(.fractionLength(2))))"
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return [
            item.confirmationNumber,
            item.bookingCode,
            item.location,
            amount,
            item.bookingUrl,
            item.ticketUrl,
            item.qrCodeUrl
        ]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func meetingEventDetail(_ item: BrowserMailMeetingEventSummary) -> String {
        [item.provider, item.location, item.url]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func shipmentTitle(_ item: BrowserMailShipmentSummary) -> String {
        let summary = item.itemSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return summary.isEmpty ? item.merchant ?? item.carrier ?? "Shipment" : summary
    }

    private func shipmentDetail(_ item: BrowserMailShipmentSummary) -> String {
        [item.merchant, item.carrier, item.trackingNumber]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func subscriptionDetail(_ item: BrowserMailSubscriptionSummary) -> String {
        let amount = item.amount.map { amount in
            "\(item.currency ?? "") \(amount.formatted(.number.precision(.fractionLength(2))))"
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let dueDate = item.nextPaymentDueAt.map {
            "Next \(Date(timeIntervalSince1970: $0 / 1000).formatted(date: .abbreviated, time: .omitted))"
        }
        return [item.provider, amount, dueDate].compactMap { $0 }.joined(separator: " · ")
    }

    private func invoiceDetail(_ item: BrowserMailInvoiceSummary) -> String {
        let amount = item.amount.map { amount in
            "\(item.currency ?? "") \(amount.formatted(.number.precision(.fractionLength(2))))"
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return [item.invoiceNumber, amount].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct MailDashboardCounts: View {
    let counts: [String: Int]

    private var orderedCounts: [(String, Int)] {
        counts
            .filter { $0.key != "unknown" }
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Category Summary")
                .font(.system(size: 13, weight: .semibold))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(orderedCounts, id: \.0) { category, count in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(color(for: category))
                            .frame(width: 7, height: 7)

                        Text(title(for: category))
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        Text("\(count)")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
    }

    private func title(for category: String) -> String {
        category
            .split(separator: "_")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private func color(for category: String) -> Color {
        switch category {
        case "security_code", "security_notifications":
            return .red
        case "purchase", "shipping", "invoice", "subscription":
            return .blue
        case "bookings", "meetings_events":
            return .green
        case "support":
            return .orange
        default:
            return .secondary
        }
    }
}

private struct MailDashboardSection<Content: View>: View {
    let title: String
    let systemImage: String
    let count: Int
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)

                Text(title)
                    .font(.system(size: 13, weight: .semibold))

                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Spacer()
            }

            if count == 0 {
                Text("No matches")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 1) {
                    content
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

private struct MailDashboardRow: View {
    let title: String
    let detail: String
    let status: String
    var imageUrl: String? = nil
    var preferredDate: Double? = nil
    let fallbackDate: Double
    let message: BrowserMailDashboardMessage?
    let onSelect: () -> Void

    private var displayDate: Double {
        preferredDate ?? message?.internalDate ?? fallbackDate
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if imageUrl != nil {
                    MailDashboardThumbnail(imageUrl: imageUrl)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title.isEmpty ? "Untitled" : title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)

                    Text(detail.isEmpty ? message?.subject ?? "Open original email for details" : detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(status.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.07), in: Capsule())

                Text(Date(timeIntervalSince1970: displayDate / 1000), style: .date)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 74, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .frame(height: 52)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct MailDashboardThumbnail: View {
    let imageUrl: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.07))

            if let imageUrl, let url = URL(string: imageUrl) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        Image(systemName: "shippingbox")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: "shippingbox")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 34, height: 34)
        .clipped()
    }
}

private struct MailDashboardMessageInspector: View {
    let messages: [BrowserMailDashboardMessage]
    let onOpenMail: () -> Void

    private var primaryMessage: BrowserMailDashboardMessage? {
        messages.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(messages.count > 1 ? "Source Emails" : "Original Email")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: onOpenMail) {
                    Image(systemName: "envelope.open")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .help("Open Mail")
            }

            if let message = primaryMessage {
                VStack(alignment: .leading, spacing: 10) {
                    inspectorField("Subject", message.subject)
                    inspectorField("From", message.from)
                    inspectorField("Message ID", message.providerMessageId)

                    if let date = message.displayDate {
                        inspectorField("Date", DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short))
                    }

                    Divider()
                        .opacity(0.45)

                    Text(message.snippet ?? "No snippet available.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }

                if messages.count > 1 {
                    Divider()
                        .opacity(0.45)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Related Emails")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)

                        ForEach(messages) { source in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.subject ?? "Untitled email")
                                    .font(.system(size: 11, weight: .semibold))
                                    .lineLimit(2)

                                HStack(spacing: 6) {
                                    Text(source.from ?? "Unknown sender")
                                        .lineLimit(1)
                                    if let date = source.displayDate {
                                        Text(DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none))
                                            .monospacedDigit()
                                    }
                                }
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Select a row to inspect the source email.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer()
        }
        .padding(18)
    }

    private func inspectorField(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value?.isEmpty == false ? value! : "-")
                .font(.system(size: 12))
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }
}
