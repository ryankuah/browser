import AppKit
import SwiftUI

struct BrowserDashboardPage: View {
    @ObservedObject var browser: BrowserState
    @ObservedObject var session: BrowserSessionController
    let onClose: () -> Void

    @State private var selectedMessage: BrowserMailDashboardMessage?

    private var dashboard: BrowserMailDashboard? { session.mailDashboard }
    private let dashboardTileHeight: CGFloat = 260
    private var dashboardColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 340), spacing: 20, alignment: .top)]
    }
    private var shipmentColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 270), spacing: 12, alignment: .top)]
    }

    var body: some View {
        ZStack {
            DashColor.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                dashHeader
                if let dashboard {
                    ScrollView {
                        commandCenter(dashboard)
                            .padding(24)
                    }
                } else {
                    emptyState
                }
            }
        }
        .foregroundStyle(DashColor.primary)
        .onAppear { session.refreshCloudData() }
        .onExitCommand(perform: onClose)
        .overlay {
            if let message = selectedMessage {
                DashEmailModal(
                    message: message,
                    onClose: { selectedMessage = nil },
                    onOpenMail: {
                        selectedMessage = nil
                        browser.newTab(url: BrowserInternalPage.mail.url)
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: selectedMessage?.id)
    }

    // MARK: Header

    private var dashHeader: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            if session.hasConnectedGoogleAccount {
                Text(session.googleAccounts.first?.email ?? "")
                    .font(.system(size: 12, weight: .medium).monospaced())
                    .foregroundStyle(DashColor.tertiary)
            } else {
                Button { session.openGoogleConnectionURL() } label: {
                    Label("Connect Google", systemImage: "link")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
            }

            Button { session.analyzeRecentMail() } label: {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 13))
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.05), in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Analyze recent mail")

            Button { session.refreshCloudData() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13))
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.05), in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Empty State

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(DashColor.muted)
            Text("No Mail Analysis Yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DashColor.secondary)
            Text("Analyze recent imported mail to populate shipments, subscriptions, purchases, and security alerts.")
                .font(.system(size: 12))
                .foregroundStyle(DashColor.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button { session.analyzeRecentMail() } label: {
                Label("Analyze Recent Mail", systemImage: "wand.and.stars")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!session.hasConnectedGoogleAccount)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Command Center

    @ViewBuilder
    private func commandCenter(_ d: BrowserMailDashboard) -> some View {
        let hasAlerts = !d.securityNotifications.isEmpty

        LazyVGrid(columns: dashboardColumns, alignment: .leading, spacing: 20) {
            if !d.shipments.isEmpty {
                shipmentsSection(d.shipments)
            }

            if !d.subscriptions.isEmpty {
                subscriptionsCard(d.subscriptions)
            }

            if !d.orders.isEmpty {
                purchasesCard(d.orders)
            }

            if !d.securityCodes.isEmpty {
                securityCodesCard(d.securityCodes)
            }

            if !d.notifications.isEmpty {
                notificationsCard(d.notifications)
            }

            if !d.supportThreads.isEmpty {
                supportCard(d.supportThreads)
            }

            if !d.invoices.isEmpty {
                invoicesCard(d.invoices)
            }

            if !d.bookings.isEmpty {
                bookingsCard(d.bookings)
            }

            if !d.meetingsEvents.isEmpty {
                meetingsEventsCard(d.meetingsEvents)
            }

            if hasAlerts {
                securityCard(d.securityNotifications)
            }

            if !d.promotions.isEmpty {
                classificationCard(title: "Promotions", systemImage: "megaphone", rows: d.promotions)
            }

            if !d.spam.isEmpty {
                classificationCard(title: "Spam", systemImage: "exclamationmark.octagon", rows: d.spam)
            }
        }
    }

    // MARK: Sections

    private func shipmentsSection(_ shipments: [BrowserMailShipmentSummary]) -> some View {
        DashCard {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("On the way")
                    .font(.system(size: 16, weight: .semibold))

                let arriving = shipments.filter {
                    let s = $0.status.lowercased()
                    return s == "out_for_delivery" || s == "out for delivery"
                }.count
                if arriving > 0 {
                    HStack(spacing: 5) {
                        Circle().fill(DashColor.amber).frame(width: 6, height: 6)
                        Text("\(arriving) arriving today")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(DashColor.amber)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(DashColor.amber.opacity(0.12), in: Capsule())
                }
                Spacer()
                Text("\(shipments.count)")
                    .font(.system(size: 12, weight: .semibold).monospaced())
                    .foregroundStyle(DashColor.muted)
            }

            ScrollView(.vertical) {
                LazyVGrid(columns: shipmentColumns, spacing: 12) {
                    ForEach(shipments) { s in
                        DashShipmentCard(shipment: s) {
                            selectedMessage = s.message ?? s.messages?.first
                        }
                    }
                }
                .padding(.trailing, 2)
            }
            .padding(.top, 13)
        }
        .frame(height: dashboardTileHeight)
    }

    private func subscriptionsCard(_ subs: [BrowserMailSubscriptionSummary]) -> some View {
        DashCard {
            HStack {
                Text("Subscriptions & renewals")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("\(subs.count)")
                    .font(.system(size: 12, weight: .semibold).monospaced())
                    .foregroundStyle(DashColor.muted)
            }
            ScrollView(.vertical) {
                VStack(spacing: 10) {
                    ForEach(subs) { sub in
                        DashSubscriptionRow(sub: sub) {
                            selectedMessage = sub.message ?? sub.messages.first
                        }
                    }
                }
                .padding(.trailing, 2)
            }
            .padding(.top, 14)
        }
        .frame(height: dashboardTileHeight)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func securityCodesCard(_ codes: [BrowserMailSecurityCode]) -> some View {
        DashCard {
            DashSectionHeader(title: "Security codes", count: "\(codes.count)", systemImage: "key.horizontal")
            ScrollView(.vertical) {
                VStack(spacing: 10) {
                    ForEach(codes) { code in
                        DashInfoRow(
                            systemImage: "number",
                            title: code.serviceName ?? "Security code",
                            detail: code.message?.subject ?? "One-time code",
                            tag: code.code,
                            date: code.message?.displayDate ?? date(fromMilliseconds: code.updatedAt),
                            tagStyle: .accent
                        ) {
                            selectedMessage = code.message
                        }
                    }
                }
                .padding(.trailing, 2)
            }
            .padding(.top, 14)
        }
        .frame(height: dashboardTileHeight)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func notificationsCard(_ notifications: [BrowserMailNotification]) -> some View {
        DashCard {
            DashSectionHeader(title: "Notifications", count: "\(notifications.count)", systemImage: "bell.badge")
            ScrollView(.vertical) {
                VStack(spacing: 10) {
                    ForEach(notifications) { notification in
                        DashInfoRow(
                            systemImage: "bell",
                            title: notification.title ?? notification.serviceName ?? dashboardTitle(notification.notificationType),
                            detail: [notification.serviceName, notification.url].compactMap { $0 }.joined(separator: " · "),
                            tag: notification.status == "unknown" ? dashboardTitle(notification.notificationType) : notification.status,
                            date: notification.message?.displayDate ?? date(fromMilliseconds: notification.occurredAt ?? notification.updatedAt)
                        ) {
                            selectedMessage = notification.message
                        }
                    }
                }
                .padding(.trailing, 2)
            }
            .padding(.top, 14)
        }
        .frame(height: dashboardTileHeight)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func supportCard(_ threads: [BrowserMailSupportThreadSummary]) -> some View {
        DashCard {
            DashSectionHeader(title: "Support", count: "\(threads.count)", systemImage: "lifepreserver")
            ScrollView(.vertical) {
                VStack(spacing: 10) {
                    ForEach(threads) { thread in
                        DashInfoRow(
                            systemImage: "lifepreserver",
                            title: thread.companyName,
                            detail: [thread.ticketId, thread.subject].compactMap { $0 }.joined(separator: " · "),
                            tag: thread.status,
                            date: thread.message?.displayDate ?? date(fromMilliseconds: thread.updatedAt)
                        ) {
                            selectedMessage = thread.message ?? thread.messages?.first
                        }
                    }
                }
                .padding(.trailing, 2)
            }
            .padding(.top, 14)
        }
        .frame(height: dashboardTileHeight)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func invoicesCard(_ invoices: [BrowserMailInvoiceSummary]) -> some View {
        DashCard {
            DashSectionHeader(title: "Invoices & payments", count: "\(invoices.count)", systemImage: "doc.text")
            ScrollView(.vertical) {
                VStack(spacing: 10) {
                    ForEach(invoices) { invoice in
                        DashInfoRow(
                            systemImage: "doc.text",
                            title: invoice.vendor ?? "Invoice",
                            detail: [invoice.invoiceNumber, moneyText(amount: invoice.amount, currency: invoice.currency)]
                                .compactMap { $0 }
                                .joined(separator: " · "),
                            tag: invoice.status,
                            date: invoice.message?.displayDate ?? date(fromMilliseconds: invoice.updatedAt)
                    ) {
                        selectedMessage = invoice.message ?? invoice.messages?.first
                    }
                }
                }
                .padding(.trailing, 2)
            }
            .padding(.top, 14)
        }
        .frame(height: dashboardTileHeight)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func bookingsCard(_ bookings: [BrowserMailBookingSummary]) -> some View {
        DashCard {
            DashSectionHeader(title: "Bookings", count: "\(bookings.count)", systemImage: "ticket")
            ScrollView(.vertical) {
                VStack(spacing: 10) {
                    ForEach(bookings) { booking in
                        DashInfoRow(
                            systemImage: "ticket",
                            title: booking.title ?? booking.provider ?? dashboardTitle(booking.category),
                            detail: [
                                booking.confirmationNumber,
                                booking.bookingCode,
                                booking.location,
                                moneyText(amount: booking.amount, currency: booking.currency)
                            ]
                                .compactMap { $0 }
                                .joined(separator: " · "),
                        tag: booking.status ?? booking.category,
                            date: date(fromMilliseconds: booking.startTime) ?? booking.message?.displayDate ?? date(fromMilliseconds: booking.updatedAt)
                    ) {
                        selectedMessage = booking.message ?? booking.messages?.first
                    }
                }
                }
                .padding(.trailing, 2)
            }
            .padding(.top, 14)
        }
        .frame(height: dashboardTileHeight)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func meetingsEventsCard(_ events: [BrowserMailMeetingEventSummary]) -> some View {
        DashCard {
            DashSectionHeader(title: "Meetings & events", count: "\(events.count)", systemImage: "calendar.badge.clock")
            ScrollView(.vertical) {
                VStack(spacing: 10) {
                    ForEach(events) { event in
                        DashInfoRow(
                            systemImage: "calendar",
                            title: event.title ?? event.provider ?? "Event",
                            detail: [event.provider, event.location, event.url].compactMap { $0 }.joined(separator: " · "),
                            tag: event.status,
                            date: date(fromMilliseconds: event.startTime) ?? event.message?.displayDate ?? date(fromMilliseconds: event.updatedAt)
                    ) {
                        selectedMessage = event.message ?? event.messages?.first
                    }
                }
                }
                .padding(.trailing, 2)
            }
            .padding(.top, 14)
        }
        .frame(height: dashboardTileHeight)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func classificationCard(
        title: String,
        systemImage: String,
        rows: [BrowserMailClassificationSummary]
    ) -> some View {
        DashCard {
            DashSectionHeader(title: title, count: "\(rows.count)", systemImage: systemImage)
            ScrollView(.vertical) {
                VStack(spacing: 10) {
                    ForEach(rows) { row in
                        DashInfoRow(
                            systemImage: systemImage,
                            title: row.message?.subject ?? dashboardTitle(row.category),
                            detail: [row.message?.from, row.reason].compactMap { $0 }.joined(separator: " · "),
                            tag: dashboardTitle(row.category),
                            date: row.message?.displayDate ?? date(fromMilliseconds: row.updatedAt)
                        ) {
                            selectedMessage = row.message
                        }
                    }
                }
                .padding(.trailing, 2)
            }
            .padding(.top, 14)
        }
        .frame(height: dashboardTileHeight)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func purchasesCard(_ orders: [BrowserMailOrderSummary]) -> some View {
        DashCard {
            HStack {
                Text("Purchases reported")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("\(orders.count)")
                    .font(.system(size: 12, weight: .semibold).monospaced())
                    .foregroundStyle(DashColor.muted)
            }
            ScrollView(.vertical) {
                VStack(spacing: 9) {
                    ForEach(orders) { order in
                        DashPurchaseRow(order: order) {
                            selectedMessage = order.messages.first ?? order.message
                        }
                    }
                }
                .padding(.trailing, 2)
            }
            .padding(.top, 14)
        }
        .frame(height: dashboardTileHeight)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func securityCard(_ alerts: [BrowserMailSecurityNotification]) -> some View {
        DashCard {
            HStack(spacing: 9) {
                Circle().fill(Color(red: 0.94, green: 0.27, blue: 0.27)).frame(width: 7, height: 7)
                Text("Security")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("\(alerts.count) alerts")
                    .font(.system(size: 12, weight: .semibold).monospaced())
                    .foregroundStyle(DashColor.muted)
            }
            ScrollView(.vertical) {
                VStack(spacing: 10) {
                    ForEach(alerts) { alert in
                        DashSecurityRow(alert: alert) {
                            selectedMessage = alert.message
                        }
                    }
                }
                .padding(.trailing, 2)
            }
            .padding(.top, 14)
        }
        .frame(height: dashboardTileHeight)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func tuckedCard(promoCount: Int, spamCount: Int) -> some View {
        DashCard(dashed: true) {
            HStack {
                Text("Tucked away")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DashColor.dim)
                Spacer()
                Text("low priority")
                    .font(.system(size: 11.5, weight: .semibold).monospaced())
                    .foregroundStyle(DashColor.muted)
            }
            HStack(spacing: 10) {
                DashTuckedStat(count: promoCount, label: "Promotions")
                DashTuckedStat(count: spamCount, label: "Spam")
            }
            .padding(.top, 12)
        }
        .frame(height: dashboardTileHeight)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func date(fromMilliseconds milliseconds: Double?) -> Date? {
        milliseconds.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    private func moneyText(amount: Double?, currency: String?) -> String? {
        guard let amount else { return nil }
        return "\(currency ?? "") \(amount.formatted(.number.precision(.fractionLength(2))))"
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }

    private func dashboardTitle(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}

// MARK: - Color Palette

private enum DashColor {
    static let bg      = Color(rgbHex: 0x0a0a0a)
    static let card    = Color(rgbHex: 0x161616)
    static let row     = Color(rgbHex: 0x1e1e1e)
    static let rowHov  = Color(rgbHex: 0x222831)
    static let sunken  = Color(rgbHex: 0x121212)
    static let primary = Color(rgbHex: 0xf2f2f2)
    static let secondary = Color(rgbHex: 0xe5e5e5)
    static let tertiary  = Color(rgbHex: 0xa3a3a3)
    static let dim       = Color(rgbHex: 0xb3b3b3)
    static let muted     = Color(rgbHex: 0x686868)
    static let faint     = Color(rgbHex: 0x7a7a7a)
    static let amber     = Color(rgbHex: 0xf7c869)
}

private extension Color {
    init(rgbHex hex: UInt32) {
        self.init(
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255
        )
    }
}

// MARK: - DashCard

private struct DashCard<Content: View>: View {
    var dashed: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(dashed ? DashColor.sunken : DashColor.card,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    dashed ? Color.white.opacity(0.1) : Color.white.opacity(0.06),
                    style: dashed ? StrokeStyle(lineWidth: 1, dash: [5, 4]) : StrokeStyle(lineWidth: 1)
                )
        }
    }
}

// MARK: - Section Header

private struct DashSectionHeader: View {
    let title: String
    let count: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DashColor.tertiary)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            Text(count)
                .font(.system(size: 12, weight: .semibold).monospaced())
                .foregroundStyle(DashColor.muted)
        }
    }
}

// MARK: - Shipment Card

private struct DashShipmentCard: View {
    let shipment: BrowserMailShipmentSummary
    let onSelect: () -> Void
    @State private var hovered = false

    private var progress: Double {
        switch shipment.status.lowercased() {
        case "delivered":                             return 1.0
        case "out_for_delivery", "out for delivery": return 0.8
        case "in_transit", "in transit":             return 0.5
        case "shipped":                              return 0.3
        default:                                     return 0.15
        }
    }

    private var statusColors: (bg: Color, fg: Color) {
        switch shipment.status.lowercased() {
        case "delivered":
            return (Color(red: 0.08, green: 0.32, blue: 0.17).opacity(0.6), Color(red: 0.29, green: 0.86, blue: 0.5))
        case "out_for_delivery", "out for delivery":
            return (DashColor.amber.opacity(0.15), DashColor.amber)
        default:
            return (Color.white.opacity(0.08), DashColor.tertiary)
        }
    }

    private var barColor: Color {
        switch shipment.status.lowercased() {
        case "delivered":                             return Color(red: 0.29, green: 0.86, blue: 0.5)
        case "out_for_delivery", "out for delivery": return DashColor.amber
        default:                                     return Color(red: 0.23, green: 0.51, blue: 0.96)
        }
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(DashColor.sunken)
                        if let urlStr = shipment.imageUrl, let url = URL(string: urlStr) {
                            AsyncImage(url: url) { phase in
                                if case .success(let img) = phase {
                                    img.resizable().scaledToFill()
                                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                } else {
                                    Image(systemName: "shippingbox").font(.system(size: 13)).foregroundStyle(DashColor.muted)
                                }
                            }
                        } else {
                            Image(systemName: "shippingbox").font(.system(size: 13)).foregroundStyle(DashColor.muted)
                        }
                    }
                    .frame(width: 42, height: 42)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(shipment.merchant ?? shipment.carrier ?? "Shipment")
                            .font(.system(size: 10, weight: .medium).monospaced())
                            .foregroundStyle(DashColor.muted)
                            .lineLimit(1)
                        Text(titleText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DashColor.secondary)
                            .lineLimit(2)
                    }
                }

                HStack {
                    Text(shipment.status.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(statusColors.fg)
                        .padding(.horizontal, 7).padding(.vertical, 2.5)
                        .background(statusColors.bg, in: Capsule())
                    Spacer()
                }
                .padding(.top, 8).padding(.bottom, 7)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.07)).frame(height: 4)
                        Capsule().fill(barColor).frame(width: geo.size.width * progress, height: 4)
                    }
                }
                .frame(height: 4)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(hovered ? DashColor.rowHov : DashColor.row,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var titleText: String {
        let s = shipment.itemSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? (shipment.merchant ?? "Package") : s
    }
}

// MARK: - Subscription Row

private struct DashSubscriptionRow: View {
    let sub: BrowserMailSubscriptionSummary
    let onSelect: () -> Void
    @State private var hovered = false

    private var daysLeft: Int? {
        guard let ms = sub.nextPaymentDueAt else { return nil }
        return Calendar.current.dateComponents([.day], from: .now, to: Date(timeIntervalSince1970: ms / 1000)).day
    }

    private var tagInfo: (label: String, bg: Color, fg: Color) {
        switch daysLeft {
        case let d? where d < 0:  return ("Overdue",    overdueColors.bg,  overdueColors.fg)
        case let d? where d <= 3: return ("Due soon",   overdueColors.bg,  overdueColors.fg)
        case let d? where d <= 7: return ("Due in \(d)d", DashColor.amber.opacity(0.15), DashColor.amber)
        default:                  return ("Active",     Color.white.opacity(0.08), DashColor.tertiary)
        }
    }

    private var overdueColors: (bg: Color, fg: Color) {
        (Color(red: 0.94, green: 0.27, blue: 0.27).opacity(0.18),
         Color(red: 0.97, green: 0.53, blue: 0.44))
    }

    private var priceText: String {
        guard let amount = sub.amount else { return "" }
        return "\(sub.currency ?? "") \(amount.formatted(.number.precision(.fractionLength(2))))".trimmingCharacters(in: .whitespaces)
    }

    private var renewText: String {
        guard let ms = sub.nextPaymentDueAt else { return "" }
        return Date(timeIntervalSince1970: ms / 1000).formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sub.provider)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DashColor.secondary)
                        .lineLimit(1)
                    Text([sub.itemSummary, priceText].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 11.5))
                        .foregroundStyle(DashColor.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(tagInfo.label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(tagInfo.fg)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(tagInfo.bg, in: Capsule())
                    if !renewText.isEmpty {
                        let suffix = daysLeft.map { " · \($0)d" } ?? ""
                        Text(renewText + suffix)
                            .font(.system(size: 11.5))
                            .foregroundStyle(DashColor.tertiary)
                    }
                }
            }
            .padding(.horizontal, 15).padding(.vertical, 15)
            .frame(maxWidth: .infinity)
            .background(hovered ? DashColor.rowHov : DashColor.row,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Purchase Row

private struct DashPurchaseRow: View {
    let order: BrowserMailOrderSummary
    let onSelect: () -> Void
    @State private var hovered = false

    private static let avatarPalette: [(bg: UInt32, fg: UInt32)] = [
        (0x1e3a5f, 0x60a5fa), (0x1a3a2a, 0x4ade80), (0x3b1f1f, 0xf87171),
        (0x2d1f3b, 0xc084fc), (0x3b2c1a, 0xfb923c), (0x1a2d3b, 0x38bdf8)
    ]

    private var avatar: (bg: Color, fg: Color) {
        let pair = Self.avatarPalette[abs(order.merchant.hashValue) % Self.avatarPalette.count]
        return (Color(rgbHex: pair.bg), Color(rgbHex: pair.fg))
    }

    private var statusColors: (bg: Color, fg: Color) {
        switch order.status.lowercased() {
        case "delivered":
            return (Color(red: 0.08, green: 0.32, blue: 0.17).opacity(0.6), Color(red: 0.29, green: 0.86, blue: 0.5))
        case "shipped":
            return (Color(red: 0.12, green: 0.23, blue: 0.37).opacity(0.6), Color(rgbHex: 0x60a5fa))
        case "cancelled", "canceled":
            return (Color(red: 0.23, green: 0.12, blue: 0.12).opacity(0.6), Color(rgbHex: 0xf87171))
        default:
            return (Color.white.opacity(0.06), DashColor.faint)
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(avatar.bg)
                    Text(String(order.merchant.prefix(1)).uppercased())
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(avatar.fg)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    let title = order.itemSummary.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty } ?? order.merchant
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DashColor.secondary)
                        .lineLimit(1)
                    let detail = [order.merchant, order.orderNumber.map { "Order \($0)" }].compactMap { $0 }.joined(separator: " · ")
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(DashColor.faint)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(order.status.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusColors.fg)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(statusColors.bg, in: Capsule())
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered ? DashColor.row : Color.clear,
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Security Row

private struct DashSecurityRow: View {
    let alert: BrowserMailSecurityNotification
    let onSelect: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.serviceName ?? alert.notificationType.split(separator: "_").map { $0.capitalized }.joined(separator: " "))
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(DashColor.secondary)
                        .lineLimit(1)
                    Text([alert.device, alert.location, alert.ipAddress].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11.5))
                        .foregroundStyle(DashColor.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let date = alert.message?.displayDate {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 11.5))
                        .foregroundStyle(DashColor.tertiary)
                }
            }
            .padding(.horizontal, 15).padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(hovered ? DashColor.rowHov : DashColor.row,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Info Row

private struct DashInfoRow: View {
    enum TagStyle {
        case standard
        case accent
    }

    let systemImage: String
    let title: String
    let detail: String
    let tag: String
    let date: Date?
    var tagStyle: TagStyle = .standard
    let onSelect: () -> Void

    @State private var hovered = false

    private var normalizedTag: String {
        tag.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private var tagColors: (bg: Color, fg: Color) {
        switch tagStyle {
        case .accent:
            return (DashColor.amber.opacity(0.15), DashColor.amber)
        case .standard:
            switch tag.lowercased() {
            case "paid", "confirmed", "active", "open", "upcoming":
                return (Color(red: 0.08, green: 0.32, blue: 0.17).opacity(0.6), Color(red: 0.29, green: 0.86, blue: 0.5))
            case "overdue", "failed", "cancelled", "canceled":
                return (Color(red: 0.23, green: 0.12, blue: 0.12).opacity(0.6), Color(rgbHex: 0xf87171))
            default:
                return (Color.white.opacity(0.06), DashColor.faint)
            }
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(DashColor.sunken)
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DashColor.tertiary)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Untitled")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DashColor.secondary)
                        .lineLimit(1)

                    Text(detail.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Open original email for details")
                        .font(.system(size: 11))
                        .foregroundStyle(DashColor.faint)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 5) {
                    Text(normalizedTag)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tagColors.fg)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(tagColors.bg, in: Capsule())

                    if let date {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 10.5))
                            .foregroundStyle(DashColor.tertiary)
                            .monospacedDigit()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .background(hovered ? DashColor.rowHov : DashColor.row,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Tucked Stat

private struct DashTuckedStat: View {
    let count: Int
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(count)")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(DashColor.dim)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(DashColor.faint)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Email Modal

private struct DashEmailModal: View {
    let message: BrowserMailDashboardMessage
    let onClose: () -> Void
    let onOpenMail: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.66)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "envelope")
                            .font(.system(size: 12))
                            .foregroundStyle(DashColor.tertiary)
                        Text("ORIGINAL EMAIL")
                            .font(.system(size: 11.5, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(DashColor.dim)
                    }
                    Spacer()
                    Button(action: onClose) {
                        Text("✕")
                            .font(.system(size: 14))
                            .foregroundStyle(DashColor.dim)
                            .frame(width: 30, height: 30)
                            .background(Color.white.opacity(0.06),
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 22)

                DashModalField("SUBJECT") {
                    Text(message.subject ?? "No subject")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DashColor.primary)
                }
                .padding(.bottom, 18)

                DashModalField("FROM") {
                    Text(message.from ?? "Unknown")
                        .font(.system(size: 13.5))
                        .foregroundStyle(DashColor.secondary)
                        .textSelection(.enabled)
                }
                .padding(.bottom, 16)

                HStack(alignment: .top, spacing: 32) {
                    if let date = message.displayDate {
                        DashModalField("DATE") {
                            Text(DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short))
                                .font(.system(size: 13))
                                .foregroundStyle(DashColor.dim)
                        }
                    }
                    DashModalField("MESSAGE ID") {
                        Text(message.providerMessageId)
                            .font(.system(size: 11.5, weight: .medium).monospaced())
                            .foregroundStyle(DashColor.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                .padding(.bottom, 18)

                Divider().opacity(0.12).padding(.bottom, 18)

                Text(message.snippet ?? "No preview available.")
                    .font(.system(size: 14))
                    .foregroundStyle(DashColor.dim)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .padding(.bottom, 22)

                Button(action: onOpenMail) {
                    HStack(spacing: 6) {
                        Text("Open original")
                        Text("↗").fontWeight(.bold)
                    }
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(DashColor.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.white.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(28)
            .frame(width: 500)
            .background(DashColor.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.55), radius: 60, y: 20)
        }
    }
}

private struct DashModalField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(DashColor.faint)
            content
        }
    }
}
