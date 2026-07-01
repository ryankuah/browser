import Combine
import Foundation
import Security
import SwiftUI
import ConvexMobile

extension ConvexClient: @unchecked Sendable {}

enum BrowserAuthPhase: Equatable {
    case unavailable(String)
    case checking
    case signedOut
    case signingIn
    case signedIn
    case failed(String)
}

@MainActor
protocol BrowserCloudSynchronizing: AnyObject, Sendable {
    func saveSettings(_ settings: [String: String]) async
    func saveProfiles(_ profiles: [BrowserProfile], activeProfileID: BrowserProfile.ID?) async
    func saveProfileState(profileID: BrowserProfile.ID, tabs: [BrowserTabSnapshot], selectedTabID: BrowserTab.ID?, bookmarks: [BrowserBookmark]) async
    func recordHistoryVisit(_ visit: BrowserCloudHistoryVisit) async
}

struct BrowserCloudConfiguration {
    static let convexDeploymentURL = firstConfiguredValue(
        ProcessInfo.processInfo.environment["BROWSER_CONVEX_URL"],
        ProcessInfo.processInfo.environment["CONVEX_URL"],
        Bundle.main.object(forInfoDictionaryKey: "BrowserConvexURL") as? String
    )

    private static func firstConfiguredValue(_ values: String?...) -> String {
        for value in values {
            let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedValue.isEmpty {
                return trimmedValue
            }
        }

        return ""
    }
}

struct BrowserCloudHistoryVisit: Sendable {
    let clientId: String
    let url: URL
    let title: String
    let tabID: UUID?
    let journeyID: UUID?
    let parentVisitID: String?
    let visitedAt: Date
    let origin: String?
}

struct BrowserMailMessage: Identifiable, Decodable, Equatable {
    let id: String
    let googleAccountId: String
    let providerMessageId: String
    let providerThreadId: String
    let labelIds: [String]
    let from: String?
    let to: String?
    let subject: String?
    let snippet: String?
    let bodyText: String?
    let bodyHtml: String?
    let internalDate: Double?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case googleAccountId
        case providerMessageId
        case providerThreadId
        case labelIds
        case from
        case to
        case subject
        case snippet
        case bodyText
        case bodyHtml
        case internalDate
    }

    var displayDate: Date? {
        internalDate.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    var displaySender: String {
        let rawSender = from?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawSender.isEmpty else {
            return "Unknown sender"
        }

        let namePart = rawSender
            .split(separator: "<", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? rawSender
        let trimmedName = namePart.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        return trimmedName.isEmpty ? rawSender : trimmedName
    }
}

struct BrowserMailMessageBody: Identifiable, Decodable, Equatable {
    let id: String
    let providerMessageId: String
    let bodyText: String?
    let bodyHtml: String?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case providerMessageId
        case bodyText
        case bodyHtml
    }
}

struct BrowserMailDashboardMessage: Identifiable, Decodable, Equatable {
    let id: String
    let googleAccountId: String
    let providerMessageId: String
    let providerThreadId: String
    let from: String?
    let subject: String?
    let snippet: String?
    let internalDate: Double?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case googleAccountId
        case providerMessageId
        case providerThreadId
        case from
        case subject
        case snippet
        case internalDate
    }

    var displayDate: Date? {
        internalDate.map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

struct BrowserMailClassificationSummary: Identifiable, Decodable, Equatable {
    let id: String
    let category: String
    let confidence: Double
    let reason: String?
    let updatedAt: Double
    let message: BrowserMailDashboardMessage?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case category
        case confidence
        case reason
        case updatedAt
        case message
    }
}

struct BrowserMailSecurityCode: Identifiable, Decodable, Equatable {
    let id: String
    let serviceName: String?
    let code: String
    let updatedAt: Double
    let message: BrowserMailDashboardMessage?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case serviceName
        case code
        case updatedAt
        case message
    }
}

struct BrowserMailSecurityNotification: Identifiable, Decodable, Equatable {
    let id: String
    let notificationType: String
    let serviceName: String?
    let accountEmail: String?
    let url: String?
    let ipAddress: String?
    let location: String?
    let device: String?
    let app: String?
    let occurredAt: Double?
    let status: String
    let updatedAt: Double
    let message: BrowserMailDashboardMessage?
    let messages: [BrowserMailDashboardMessage]?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case notificationType
        case serviceName
        case accountEmail
        case url
        case ipAddress
        case location
        case device
        case app
        case occurredAt
        case status
        case updatedAt
        case message
        case messages
    }
}

struct BrowserMailNotification: Identifiable, Decodable, Equatable {
    let id: String
    let notificationType: String
    let serviceName: String?
    let title: String?
    let status: String
    let url: String?
    let occurredAt: Double?
    let updatedAt: Double
    let message: BrowserMailDashboardMessage?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case notificationType
        case serviceName
        case title
        case status
        case url
        case occurredAt
        case updatedAt
        case message
    }
}

struct BrowserMailSupportThreadSummary: Identifiable, Decodable, Equatable {
    let id: String
    let companyName: String
    let ticketId: String?
    let subject: String?
    let status: String
    let updatedAt: Double
    let message: BrowserMailDashboardMessage?
    let messages: [BrowserMailDashboardMessage]?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case companyName
        case ticketId
        case subject
        case status
        case updatedAt
        case message
        case messages
    }
}

struct BrowserMailOrderSummary: Identifiable, Decodable, Equatable {
    let id: String
    let merchant: String
    let orderNumber: String?
    let itemSummary: String?
    let imageUrl: String?
    let status: String
    let updatedAt: Double
    let message: BrowserMailDashboardMessage?
    let messages: [BrowserMailDashboardMessage]

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case merchant
        case orderNumber
        case itemSummary
        case imageUrl
        case status
        case updatedAt
        case message
        case messages
    }
}

struct BrowserMailShipmentSummary: Identifiable, Decodable, Equatable {
    let id: String
    let merchant: String?
    let carrier: String?
    let trackingNumber: String?
    let trackingUrl: String?
    let itemSummary: String?
    let imageUrl: String?
    let orderNumber: String?
    let status: String
    let updatedAt: Double
    let message: BrowserMailDashboardMessage?
    let messages: [BrowserMailDashboardMessage]?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case merchant
        case carrier
        case trackingNumber
        case trackingUrl
        case itemSummary
        case imageUrl
        case orderNumber
        case status
        case updatedAt
        case message
        case messages
    }
}

struct BrowserMailSubscriptionSummary: Identifiable, Decodable, Equatable {
    let id: String
    let provider: String
    let itemSummary: String
    let imageUrl: String?
    let amount: Double?
    let currency: String?
    let nextPaymentDueAt: Double?
    let status: String
    let updatedAt: Double
    let message: BrowserMailDashboardMessage?
    let messages: [BrowserMailDashboardMessage]

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case provider
        case itemSummary
        case imageUrl
        case amount
        case currency
        case nextPaymentDueAt
        case status
        case updatedAt
        case message
        case messages
    }
}

struct BrowserMailInvoiceSummary: Identifiable, Decodable, Equatable {
    let id: String
    let vendor: String?
    let invoiceNumber: String?
    let amount: Double?
    let currency: String?
    let status: String
    let updatedAt: Double
    let message: BrowserMailDashboardMessage?
    let messages: [BrowserMailDashboardMessage]?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case vendor
        case invoiceNumber
        case amount
        case currency
        case status
        case updatedAt
        case message
        case messages
    }
}

struct BrowserMailBookingSummary: Identifiable, Decodable, Equatable {
    let id: String
    let category: String
    let provider: String?
    let confirmationNumber: String?
    let bookingCode: String?
    let bookingUrl: String?
    let qrCodeUrl: String?
    let ticketUrl: String?
    let amount: Double?
    let currency: String?
    let title: String?
    let location: String?
    let startTime: Double?
    let endTime: Double?
    let status: String?
    let updatedAt: Double
    let message: BrowserMailDashboardMessage?
    let messages: [BrowserMailDashboardMessage]?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case category
        case provider
        case confirmationNumber
        case bookingCode
        case bookingUrl
        case qrCodeUrl
        case ticketUrl
        case amount
        case currency
        case title
        case location
        case startTime
        case endTime
        case status
        case updatedAt
        case message
        case messages
    }
}

struct BrowserMailMeetingEventSummary: Identifiable, Decodable, Equatable {
    let id: String
    let source: String
    let provider: String?
    let eventKey: String
    let title: String?
    let location: String?
    let url: String?
    let startTime: Double?
    let endTime: Double?
    let status: String
    let updatedAt: Double
    let message: BrowserMailDashboardMessage?
    let messages: [BrowserMailDashboardMessage]?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case source
        case provider
        case eventKey
        case title
        case location
        case url
        case startTime
        case endTime
        case status
        case updatedAt
        case message
        case messages
    }
}

struct BrowserMailDashboard: Decodable, Equatable {
    let categoryCounts: [String: Int]
    let securityCodes: [BrowserMailSecurityCode]
    let securityNotifications: [BrowserMailSecurityNotification]
    let notifications: [BrowserMailNotification]
    let supportThreads: [BrowserMailSupportThreadSummary]
    let orders: [BrowserMailOrderSummary]
    let shipments: [BrowserMailShipmentSummary]
    let subscriptions: [BrowserMailSubscriptionSummary]
    let invoices: [BrowserMailInvoiceSummary]
    let bookings: [BrowserMailBookingSummary]
    let meetingsEvents: [BrowserMailMeetingEventSummary]
    let promotions: [BrowserMailClassificationSummary]
    let spam: [BrowserMailClassificationSummary]
}

enum BrowserMailDashboardSection: String, CaseIterable, Hashable {
    case shipments
    case subscriptions
    case orders
    case securityCodes
    case notifications
    case supportThreads
    case invoices
    case bookings
    case meetingsEvents
    case securityNotifications
    case promotions
    case spam
}

struct BrowserMailDashboardPage<Row: Decodable & Equatable>: Decodable, Equatable {
    let page: [Row]
    let isDone: Bool
    let continueCursor: String
}

extension BrowserMailDashboard {
    static let empty = BrowserMailDashboard(
        categoryCounts: [:],
        securityCodes: [],
        securityNotifications: [],
        notifications: [],
        supportThreads: [],
        orders: [],
        shipments: [],
        subscriptions: [],
        invoices: [],
        bookings: [],
        meetingsEvents: [],
        promotions: [],
        spam: []
    )

    func updating(
        categoryCounts: [String: Int]? = nil,
        securityCodes: [BrowserMailSecurityCode]? = nil,
        securityNotifications: [BrowserMailSecurityNotification]? = nil,
        notifications: [BrowserMailNotification]? = nil,
        supportThreads: [BrowserMailSupportThreadSummary]? = nil,
        orders: [BrowserMailOrderSummary]? = nil,
        shipments: [BrowserMailShipmentSummary]? = nil,
        subscriptions: [BrowserMailSubscriptionSummary]? = nil,
        invoices: [BrowserMailInvoiceSummary]? = nil,
        bookings: [BrowserMailBookingSummary]? = nil,
        meetingsEvents: [BrowserMailMeetingEventSummary]? = nil,
        promotions: [BrowserMailClassificationSummary]? = nil,
        spam: [BrowserMailClassificationSummary]? = nil
    ) -> BrowserMailDashboard {
        BrowserMailDashboard(
            categoryCounts: categoryCounts ?? self.categoryCounts,
            securityCodes: securityCodes ?? self.securityCodes,
            securityNotifications: securityNotifications ?? self.securityNotifications,
            notifications: notifications ?? self.notifications,
            supportThreads: supportThreads ?? self.supportThreads,
            orders: orders ?? self.orders,
            shipments: shipments ?? self.shipments,
            subscriptions: subscriptions ?? self.subscriptions,
            invoices: invoices ?? self.invoices,
            bookings: bookings ?? self.bookings,
            meetingsEvents: meetingsEvents ?? self.meetingsEvents,
            promotions: promotions ?? self.promotions,
            spam: spam ?? self.spam
        )
    }
}

struct BrowserMailThread: Identifiable, Equatable {
    let id: String
    /// Messages within the thread, oldest first.
    let messages: [BrowserMailMessage]

    var latestMessage: BrowserMailMessage {
        messages.last ?? messages[0]
    }

    static func grouping(_ messages: [BrowserMailMessage]) -> [BrowserMailThread] {
        Dictionary(grouping: messages, by: \.providerThreadId)
            .map { threadID, messages in
                BrowserMailThread(
                    id: threadID,
                    messages: messages.sorted { lhs, rhs in
                        (lhs.displayDate ?? .distantPast) < (rhs.displayDate ?? .distantPast)
                    }
                )
            }
            .sorted { lhs, rhs in
                (lhs.latestMessage.displayDate ?? .distantPast) > (rhs.latestMessage.displayDate ?? .distantPast)
            }
    }
}

struct BrowserGoogleCalendar: Identifiable, Decodable, Equatable {
    let id: String
    let summary: String
    let primary: Bool
    let selected: Bool

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case summary
        case primary
        case selected
    }
}

struct BrowserGoogleAccount: Identifiable, Decodable, Equatable {
    let id: String
    let email: String
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case email
        case displayName
    }
}

struct BrowserMailBackfillState: Identifiable, Decodable, Equatable {
    let googleAccountId: String
    let email: String
    let status: String
    let query: String?
    let pageCount: Int
    let maxPageCount: Int?
    let importedCount: Int
    let scannedCount: Int
    let resultSizeEstimate: Int?
    let lastError: String?

    var id: String {
        googleAccountId
    }

    var isRunning: Bool {
        status == "queued" || status == "running"
    }
}

struct BrowserCalendarEvent: Identifiable, Decodable, Equatable {
    let id: String
    let providerCalendarId: String
    let status: String
    let summary: String?
    let location: String?
    let startText: String?
    let endText: String?
    let startTimestamp: Double?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case providerCalendarId
        case status
        case summary
        case location
        case startText
        case endText
        case startTimestamp
    }

    var startDate: Date? {
        startTimestamp.map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

@MainActor
final class BrowserSessionController: ObservableObject, BrowserCloudSynchronizing {
    @Published private(set) var authPhase: BrowserAuthPhase
    @Published private(set) var mailMessages: [BrowserMailMessage] = []
    @Published private(set) var mailMessageBodies: [String: BrowserMailMessageBody] = [:]
    @Published private(set) var mailDashboard: BrowserMailDashboard?
    @Published private(set) var dashboardLoadingSections: Set<BrowserMailDashboardSection> = []
    @Published private(set) var dashboardDoneSections: Set<BrowserMailDashboardSection> = []
    @Published private(set) var hasMoreMailMessages = true
    @Published private(set) var isLoadingMoreMailMessages = false
    @Published private(set) var mailBackfillStates: [BrowserMailBackfillState] = []
    @Published private(set) var googleAccounts: [BrowserGoogleAccount] = []
    @Published private(set) var calendars: [BrowserGoogleCalendar] = []
    @Published private(set) var calendarEvents: [BrowserCalendarEvent] = []
    @Published private(set) var googleConnectURL: URL?
    @Published private(set) var oauthPresentationURL: URL?
    @Published private(set) var username: String?

    private let deploymentURL: String
    private let client: ConvexClient?
    private let tokenStore = BrowserSessionTokenStore()
    private var cancellables: Set<AnyCancellable> = []
    private var mailMessagesCancellable: AnyCancellable?
    private var mailMessageBodyCancellables: [String: AnyCancellable] = [:]
    private var dashboardPageCancellables: [BrowserMailDashboardSection: AnyCancellable] = [:]
    private var dashboardPaginationCursors: [BrowserMailDashboardSection: String] = [:]
    private var hasMigratedLocalState = false
    private var hasAttemptedCachedLogin = false
    private var sessionToken: String?

    private let mailMessagePageSize: Double = 100
    private var mailMessagesLimit: Double = 100
    private let dashboardPageSize: Double = 12

    var isSignedIn: Bool {
        authPhase == .signedIn
    }

    var hasConnectedGoogleAccount: Bool {
        !googleAccounts.isEmpty
    }

    init(deploymentURL: String = BrowserCloudConfiguration.convexDeploymentURL) {
        self.deploymentURL = deploymentURL
        guard !deploymentURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            authPhase = .unavailable("Set BROWSER_CONVEX_URL, CONVEX_URL, or BrowserConvexURL to your Convex deployment URL.")
            client = nil
            return
        }

        client = ConvexClient(deploymentUrl: deploymentURL)
        authPhase = .checking
    }

    func loginFromCache() {
        guard !hasAttemptedCachedLogin else {
            return
        }
        hasAttemptedCachedLogin = true

        guard let client else {
            return
        }

        guard let token = tokenStore.load() else {
            authPhase = .signedOut
            return
        }

        Task {
            do {
                let response: CurrentUserResponse? = try await client.mutation(
                    "users:validateSession",
                    with: ["sessionToken": token]
                )
                guard let response else {
                    tokenStore.clear()
                    authPhase = .signedOut
                    return
                }
                sessionToken = token
                username = response.username
                authPhase = .signedIn
                refreshCloudData()
            } catch {
                tokenStore.clear()
                authPhase = .signedOut
            }
        }
    }

    func login(username: String, password: String) {
        guard let client else {
            return
        }

        hasAttemptedCachedLogin = true
        authPhase = .signingIn
        Task {
            do {
                let response: AuthResponse = try await client.mutation(
                    "users:login",
                    with: ["username": username, "password": password]
                )
                sessionToken = response.sessionToken
                self.username = response.username
                tokenStore.save(response.sessionToken)
                authPhase = .signedIn
                refreshCloudData()
            } catch {
                authPhase = .failed(error.localizedDescription)
            }
        }
    }

    func register(username: String, password: String) {
        guard let client else {
            return
        }

        hasAttemptedCachedLogin = true
        authPhase = .signingIn
        Task {
            do {
                let response: AuthResponse = try await client.mutation(
                    "users:register",
                    with: ["username": username, "password": password]
                )
                sessionToken = response.sessionToken
                self.username = response.username
                tokenStore.save(response.sessionToken)
                authPhase = .signedIn
                refreshCloudData()
            } catch {
                authPhase = .failed(error.localizedDescription)
            }
        }
    }

    func logout() {
        guard let client else {
            authPhase = .signedOut
            return
        }

        Task {
            if let sessionToken {
                try? await client.mutation("users:logout", with: ["sessionToken": sessionToken])
            }
            tokenStore.clear()
            sessionToken = nil
            hasAttemptedCachedLogin = true
            username = nil
            mailMessages = []
            mailMessageBodies = [:]
            mailDashboard = nil
            resetMailDashboardPagination()
            mailMessageBodyCancellables.removeAll()
            mailMessagesLimit = mailMessagePageSize
            hasMoreMailMessages = true
            isLoadingMoreMailMessages = false
            mailMessagesCancellable = nil
            mailBackfillStates = []
            googleAccounts = []
            calendars = []
            calendarEvents = []
            googleConnectURL = nil
            oauthPresentationURL = nil
            authPhase = .signedOut
        }
    }

    func migrateLocalStateIfNeeded(from browser: BrowserState) {
        guard isSignedIn, !hasMigratedLocalState else {
            return
        }

        hasMigratedLocalState = true
        Task {
            await saveProfiles(browser.profiles, activeProfileID: browser.selectedProfileID)
            await saveSettings([
                "activeProfileID": browser.selectedProfileID?.uuidString ?? "",
                "bezelStyle": browser.bezelStyle.rawValue,
                "searchEngine": browser.searchEngine.rawValue,
            ])
            if let selectedProfileID = browser.selectedProfileID {
                await saveProfileState(
                    profileID: selectedProfileID,
                    tabs: browser.cloudSessionSnapshot().tabs,
                    selectedTabID: browser.cloudSessionSnapshot().selectedTabID,
                    bookmarks: browser.bookmarks
                )
            }
        }
    }

    func refreshCloudData() {
        guard let client, let sessionToken, isSignedIn else {
            return
        }

        cancellables.removeAll()
        resetMailDashboardPagination()
        client.subscribe(
            to: "google:connectedAccounts",
            with: ["sessionToken": sessionToken],
            yielding: [BrowserGoogleAccount].self
        )
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    if case .failure(let error) = completion {
                        NSLog("Convex Google account subscription failed: \(error)")
                    }
                },
                receiveValue: { [weak self] accounts in
                    self?.googleAccounts = accounts
                }
            )
            .store(in: &cancellables)

        subscribeToMailMessages(limit: mailMessagesLimit)

        client.subscribe(
            to: "mail:backfillStates",
            with: ["sessionToken": sessionToken],
            yielding: [BrowserMailBackfillState].self
        )
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    if case .failure(let error) = completion {
                        NSLog("Convex mail backfill subscription failed: \(error)")
                    }
                },
                receiveValue: { [weak self] states in
                    self?.mailBackfillStates = states
                }
            )
            .store(in: &cancellables)

        client.subscribe(
            to: "mail:dashboard",
            with: ["sessionToken": sessionToken],
            yielding: BrowserMailDashboard.self
        )
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    if case .failure(let error) = completion {
                        NSLog("Convex mail dashboard subscription failed: \(error)")
                    }
                },
                receiveValue: { [weak self] dashboard in
                    self?.mergeDashboardSnapshot(dashboard)
                }
            )
            .store(in: &cancellables)

        client.subscribe(
            to: "calendar:calendars",
            with: ["sessionToken": sessionToken],
            yielding: [BrowserGoogleCalendar].self
        )
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    if case .failure(let error) = completion {
                        NSLog("Convex calendar subscription failed: \(error)")
                    }
                },
                receiveValue: { [weak self] calendars in
                    self?.calendars = calendars
                }
            )
            .store(in: &cancellables)

        client.subscribe(
            to: "calendar:events",
            with: ["sessionToken": sessionToken, "limit": Double(200)],
            yielding: [BrowserCalendarEvent].self
        )
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    if case .failure(let error) = completion {
                        NSLog("Convex event subscription failed: \(error)")
                    }
                },
                receiveValue: { [weak self] events in
                    self?.calendarEvents = events
                }
            )
            .store(in: &cancellables)
    }

    func hasMoreDashboardSection(_ section: BrowserMailDashboardSection) -> Bool {
        !dashboardDoneSections.contains(section)
    }

    func isLoadingDashboardSection(_ section: BrowserMailDashboardSection) -> Bool {
        dashboardLoadingSections.contains(section)
    }

    func loadMoreDashboardSection(_ section: BrowserMailDashboardSection) {
        guard let client, let sessionToken, isSignedIn,
              !dashboardLoadingSections.contains(section),
              !dashboardDoneSections.contains(section) else {
            return
        }

        dashboardLoadingSections.insert(section)
        let cursor = dashboardPaginationCursors[section]
        let paginationOpts = [
            "numItems": dashboardPageSize,
            "cursor": cursor,
        ] as [String: ConvexEncodable?]
        let args = [
            "sessionToken": sessionToken,
            "section": section.rawValue,
            "paginationOpts": paginationOpts,
        ] as [String: ConvexEncodable?]

        switch section {
        case .shipments:
            subscribeDashboardPage(
                client,
                section: section,
                args: args,
                rows: \.shipments,
                update: { $0.updating(shipments: $1) },
                rowType: BrowserMailShipmentSummary.self
            )
        case .subscriptions:
            subscribeDashboardPage(
                client,
                section: section,
                args: args,
                rows: \.subscriptions,
                update: { $0.updating(subscriptions: $1) },
                rowType: BrowserMailSubscriptionSummary.self
            )
        case .orders:
            subscribeDashboardPage(
                client,
                section: section,
                args: args,
                rows: \.orders,
                update: { $0.updating(orders: $1) },
                rowType: BrowserMailOrderSummary.self
            )
        case .securityCodes:
            subscribeDashboardPage(
                client,
                section: section,
                args: args,
                rows: \.securityCodes,
                update: { $0.updating(securityCodes: $1) },
                rowType: BrowserMailSecurityCode.self
            )
        case .notifications:
            subscribeDashboardPage(
                client,
                section: section,
                args: args,
                rows: \.notifications,
                update: { $0.updating(notifications: $1) },
                rowType: BrowserMailNotification.self
            )
        case .supportThreads:
            subscribeDashboardPage(
                client,
                section: section,
                args: args,
                rows: \.supportThreads,
                update: { $0.updating(supportThreads: $1) },
                rowType: BrowserMailSupportThreadSummary.self
            )
        case .invoices:
            subscribeDashboardPage(
                client,
                section: section,
                args: args,
                rows: \.invoices,
                update: { $0.updating(invoices: $1) },
                rowType: BrowserMailInvoiceSummary.self
            )
        case .bookings:
            subscribeDashboardPage(
                client,
                section: section,
                args: args,
                rows: \.bookings,
                update: { $0.updating(bookings: $1) },
                rowType: BrowserMailBookingSummary.self
            )
        case .meetingsEvents:
            subscribeDashboardPage(
                client,
                section: section,
                args: args,
                rows: \.meetingsEvents,
                update: { $0.updating(meetingsEvents: $1) },
                rowType: BrowserMailMeetingEventSummary.self
            )
        case .securityNotifications:
            subscribeDashboardPage(
                client,
                section: section,
                args: args,
                rows: \.securityNotifications,
                update: { $0.updating(securityNotifications: $1) },
                rowType: BrowserMailSecurityNotification.self
            )
        case .promotions:
            subscribeDashboardPage(
                client,
                section: section,
                args: args,
                rows: \.promotions,
                update: { $0.updating(promotions: $1) },
                rowType: BrowserMailClassificationSummary.self
            )
        case .spam:
            subscribeDashboardPage(
                client,
                section: section,
                args: args,
                rows: \.spam,
                update: { $0.updating(spam: $1) },
                rowType: BrowserMailClassificationSummary.self
            )
        }
    }

    private func subscribeDashboardPage<Row: Decodable & Identifiable & Equatable>(
        _ client: ConvexClient,
        section: BrowserMailDashboardSection,
        args: [String: ConvexEncodable?],
        rows: KeyPath<BrowserMailDashboard, [Row]>,
        update: @escaping (BrowserMailDashboard, [Row]) -> BrowserMailDashboard,
        rowType _: Row.Type
    ) where Row.ID: Hashable {
        dashboardPageCancellables[section]?.cancel()
        dashboardPageCancellables[section] = client.subscribe(
            to: "mail:dashboardPage",
            with: args,
            yielding: BrowserMailDashboardPage<Row>.self
        )
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    guard let self else { return }
                    if case .failure(let error) = completion {
                        NSLog("Convex mail dashboard page subscription failed: \(error)")
                    }
                    self.dashboardLoadingSections.remove(section)
                    self.dashboardPageCancellables[section] = nil
                },
                receiveValue: { [weak self] page in
                    guard let self else { return }
                    let dashboard = self.mailDashboard ?? .empty
                    let merged = Self.mergedRows(existing: dashboard[keyPath: rows], incoming: page.page)
                    self.mailDashboard = update(dashboard, merged.rows)
                    self.dashboardPaginationCursors[section] = page.continueCursor
                    if page.isDone {
                        self.dashboardDoneSections.insert(section)
                    } else {
                        self.dashboardDoneSections.remove(section)
                    }
                    self.dashboardLoadingSections.remove(section)
                    self.dashboardPageCancellables[section]?.cancel()
                    self.dashboardPageCancellables[section] = nil

                    if merged.insertedCount == 0, !page.isDone {
                        DispatchQueue.main.async {
                            self.loadMoreDashboardSection(section)
                        }
                    }
                }
            )
    }

    private func mergeDashboardSnapshot(_ snapshot: BrowserMailDashboard) {
        guard let current = mailDashboard else {
            mailDashboard = snapshot
            return
        }

        mailDashboard = snapshot.updating(
            securityCodes: Self.mergedRows(existing: snapshot.securityCodes, incoming: current.securityCodes).rows,
            securityNotifications: Self.mergedRows(
                existing: snapshot.securityNotifications,
                incoming: current.securityNotifications
            ).rows,
            notifications: Self.mergedRows(existing: snapshot.notifications, incoming: current.notifications).rows,
            supportThreads: Self.mergedRows(existing: snapshot.supportThreads, incoming: current.supportThreads).rows,
            orders: Self.mergedRows(existing: snapshot.orders, incoming: current.orders).rows,
            shipments: Self.mergedRows(existing: snapshot.shipments, incoming: current.shipments).rows,
            subscriptions: Self.mergedRows(existing: snapshot.subscriptions, incoming: current.subscriptions).rows,
            invoices: Self.mergedRows(existing: snapshot.invoices, incoming: current.invoices).rows,
            bookings: Self.mergedRows(existing: snapshot.bookings, incoming: current.bookings).rows,
            meetingsEvents: Self.mergedRows(existing: snapshot.meetingsEvents, incoming: current.meetingsEvents).rows,
            promotions: Self.mergedRows(existing: snapshot.promotions, incoming: current.promotions).rows,
            spam: Self.mergedRows(existing: snapshot.spam, incoming: current.spam).rows
        )
    }

    private func resetMailDashboardPagination() {
        dashboardPageCancellables.values.forEach { $0.cancel() }
        dashboardPageCancellables.removeAll()
        dashboardPaginationCursors.removeAll()
        dashboardLoadingSections.removeAll()
        dashboardDoneSections.removeAll()
    }

    private static func mergedRows<Row: Identifiable>(
        existing: [Row],
        incoming: [Row]
    ) -> (rows: [Row], insertedCount: Int) where Row.ID: Hashable {
        var seen = Set(existing.map(\.id))
        var merged = existing
        var insertedCount = 0
        for row in incoming where !seen.contains(row.id) {
            seen.insert(row.id)
            merged.append(row)
            insertedCount += 1
        }
        return (merged, insertedCount)
    }

    func loadMoreMailMessages() {
        guard hasMoreMailMessages, !isLoadingMoreMailMessages else {
            return
        }

        isLoadingMoreMailMessages = true
        mailMessagesLimit += mailMessagePageSize
        subscribeToMailMessages(limit: mailMessagesLimit)
    }

    func loadMailMessageBody(_ message: BrowserMailMessage) {
        guard mailMessageBodies[message.providerMessageId] == nil,
              mailMessageBodyCancellables[message.providerMessageId] == nil,
              let client,
              let sessionToken else {
            return
        }

        mailMessageBodyCancellables[message.providerMessageId] = client.subscribe(
            to: "mail:messageBody",
            with: [
                "sessionToken": sessionToken,
                "googleAccountId": message.googleAccountId,
                "providerMessageId": message.providerMessageId
            ],
            yielding: BrowserMailMessageBody?.self
        )
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    self?.mailMessageBodyCancellables[message.providerMessageId] = nil
                    if case .failure(let error) = completion {
                        NSLog("Convex mail body subscription failed: \(error)")
                    }
                },
                receiveValue: { [weak self] body in
                    if let body {
                        self?.mailMessageBodies[message.providerMessageId] = body
                    }
                    self?.mailMessageBodyCancellables[message.providerMessageId]?.cancel()
                    self?.mailMessageBodyCancellables[message.providerMessageId] = nil
                }
            )
    }

    func analyzeRecentMail(limit: Double = 500) {
        guard let client, let sessionToken, isSignedIn else {
            return
        }

        Task {
            do {
                try await client.mutation(
                    "mail:analyzeRecentMessages",
                    with: ["sessionToken": sessionToken, "limit": limit]
                )
            } catch {
                NSLog("Convex mail analysis scheduling failed: \(error.localizedDescription)")
            }
        }
    }

    private func subscribeToMailMessages(limit: Double) {
        guard let client, let sessionToken else {
            return
        }

        mailMessagesCancellable = client.subscribe(
            to: "mail:messages",
            with: ["sessionToken": sessionToken, "limit": limit],
            yielding: [BrowserMailMessage].self
        )
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    self?.isLoadingMoreMailMessages = false
                    if case .failure(let error) = completion {
                        NSLog("Convex mail subscription failed: \(error)")
                    }
                },
                receiveValue: { [weak self] messages in
                    guard let self else {
                        return
                    }
                    self.mailMessages = messages
                    self.hasMoreMailMessages = Double(messages.count) >= limit
                    self.isLoadingMoreMailMessages = false
                }
            )
    }

    func prepareGoogleConnection() {
        guard let client, let sessionToken, isSignedIn else {
            return
        }

        Task {
            do {
                let response: GoogleOAuthStartResponse = try await client.mutation(
                    "google:startOAuth",
                    with: ["sessionToken": sessionToken]
                )
                googleConnectURL = URL(string: response.authorizationUrl)
            } catch {
                authPhase = .failed(error.localizedDescription)
            }
        }
    }

    func openGoogleConnectionURL() {
        guard let client, let sessionToken, isSignedIn else {
            return
        }

        Task {
            do {
                let response: GoogleOAuthStartResponse = try await client.mutation(
                    "google:startOAuth",
                    with: ["sessionToken": sessionToken]
                )
                guard let url = URL(string: response.authorizationUrl) else {
                    authPhase = .failed("Google OAuth returned an invalid authorization URL.")
                    return
                }
                googleConnectURL = url
                oauthPresentationURL = url
            } catch {
                authPhase = .failed(error.localizedDescription)
            }
        }
    }

    func dismissOAuthPresentation() {
        oauthPresentationURL = nil
    }

    func handleGoogleOAuthCallback(_ url: URL) {
        guard url.host()?.lowercased() == "google",
              url.path == "/oauth/callback",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return
        }

        googleConnectURL = nil
        oauthPresentationURL = nil

        let status = components.queryItems?.first { $0.name == "status" }?.value
        if status == "error" {
            let message = components.queryItems?.first { $0.name == "message" }?.value
            if message?.localizedCaseInsensitiveContains("expired") == true, !isSignedIn {
                authPhase = .signedOut
                return
            }
            authPhase = .failed(message ?? "Google OAuth failed.")
            return
        }

        if isSignedIn {
            refreshCloudData()
        }
    }

    func setCalendar(_ calendar: BrowserGoogleCalendar, selected: Bool) {
        guard let client, let sessionToken else {
            return
        }

        Task {
            do {
                try await client.mutation(
                    "google:setCalendarSelected",
                    with: ["sessionToken": sessionToken, "calendarId": calendar.id, "selected": selected]
                )
                refreshCloudData()
            } catch {
                NSLog("Calendar selection failed: \(error.localizedDescription)")
            }
        }
    }

    func saveSettings(_ settings: [String: String]) async {
        guard let client, let sessionToken, isSignedIn else {
            return
        }

        let items: [ConvexEncodable?] = settings
            .filter { !$0.value.isEmpty }
            .map { ["key": $0.key, "value": $0.value] as [String: ConvexEncodable?] }
        guard !items.isEmpty else {
            return
        }

        do {
            try await client.mutation("browser:saveSettings", with: ["sessionToken": sessionToken, "settings": items])
        } catch {
            NSLog("Convex settings save failed: \(error.localizedDescription)")
        }
    }

    func saveProfiles(_ profiles: [BrowserProfile], activeProfileID: BrowserProfile.ID?) async {
        guard let client, let sessionToken, isSignedIn else {
            return
        }

        let payload: [ConvexEncodable?] = profiles.map {
            [
                "clientId": $0.id.uuidString,
                "name": $0.name,
                "colorHex": $0.colorHex,
                "position": $0.position,
            ] as [String: ConvexEncodable?]
        }

        do {
            try await client.mutation(
                "browser:upsertProfiles",
                with: [
                    "profiles": payload,
                    "activeProfileClientId": activeProfileID?.uuidString,
                    "sessionToken": sessionToken,
                ]
            )
        } catch {
            NSLog("Convex profile save failed: \(error.localizedDescription)")
        }
    }

    func saveProfileState(
        profileID: BrowserProfile.ID,
        tabs: [BrowserTabSnapshot],
        selectedTabID: BrowserTab.ID?,
        bookmarks: [BrowserBookmark]
    ) async {
        guard let client, let sessionToken, isSignedIn else {
            return
        }

        let tabPayload: [ConvexEncodable?] = tabs.map {
            [
                "clientId": $0.id.uuidString,
                "position": $0.position,
                "title": $0.title,
                "url": $0.url?.absoluteString,
            ] as [String: ConvexEncodable?]
        }
        let bookmarkPayload: [ConvexEncodable?] = bookmarks.enumerated().map { index, bookmark in
            [
                "clientId": bookmark.id.uuidString,
                "position": index,
                "title": bookmark.title,
                "url": bookmark.url.absoluteString,
            ] as [String: ConvexEncodable?]
        }

        do {
            try await client.mutation(
                "browser:saveProfileState",
                with: [
                    "profileClientId": profileID.uuidString,
                    "sessionToken": sessionToken,
                    "selectedTabClientId": selectedTabID?.uuidString,
                    "tabs": tabPayload,
                    "bookmarks": bookmarkPayload,
                ]
            )
        } catch {
            NSLog("Convex profile state save failed: \(error.localizedDescription)")
        }
    }

    func recordHistoryVisit(_ visit: BrowserCloudHistoryVisit) async {
        guard let client, let sessionToken, isSignedIn else {
            return
        }

        let host = visit.url.host() ?? ""
        let registrableDomain = host
        let subdomain: String? = nil

        do {
            try await client.mutation(
                "browser:recordHistoryVisit",
                with: [
                    "clientId": visit.clientId,
                    "sessionToken": sessionToken,
                    "url": visit.url.absoluteString,
                    "title": visit.title,
                    "tabClientId": visit.tabID?.uuidString,
                    "journeyClientId": visit.journeyID?.uuidString,
                    "parentVisitClientId": visit.parentVisitID,
                    "visitedAt": visit.visitedAt.timeIntervalSince1970 * 1000,
                    "origin": visit.origin,
                    "host": host,
                    "registrableDomain": registrableDomain,
                    "subdomain": subdomain,
                ]
            )
        } catch {
            NSLog("Convex history save failed: \(error.localizedDescription)")
        }
    }

}

private struct AuthResponse: Decodable {
    let sessionToken: String
    let username: String
}

private struct CurrentUserResponse: Decodable {
    let username: String
}

private struct GoogleOAuthStartResponse: Decodable {
    let authorizationUrl: String
}

private final class BrowserSessionTokenStore {
    private let service = "com.ryankuah.browser.session"
    private let account = "default"

    func save(_ token: String) {
        clear()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8)
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct BrowserAuthGate<Content: View>: View {
    @ObservedObject var session: BrowserSessionController
    let content: () -> Content

    var body: some View {
        Group {
            switch session.authPhase {
            case .signedIn:
                content()
            case .unavailable(let message):
                BrowserAuthUnavailableView(message: message)
            case .checking:
                BrowserAuthCheckingView()
            default:
                BrowserAuthView(session: session)
            }
        }
        .onAppear {
            session.loginFromCache()
        }
    }
}

private struct BrowserAuthCheckingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)

            Text("Signing in")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct BrowserAuthView: View {
    @ObservedObject var session: BrowserSessionController
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text("Sign in to Browser")
                    .font(.system(size: 22, weight: .semibold))

                Text("Use a username and password to sync mail, calendar, tabs, history, settings, and bookmarks with your Convex backend.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            VStack(spacing: 8) {
                TextField("Username", text: $username)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .frame(width: 260, height: 34)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    }

                SecureField("Password", text: $password)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .frame(width: 260, height: 34)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    }
            }

            HStack(spacing: 8) {
                Button {
                    session.login(username: username, password: password)
                } label: {
                    Text(buttonTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(minWidth: 110, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitDisabled)

                Button {
                    session.register(username: username, password: password)
                } label: {
                    Text("Create Account")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(minWidth: 120, minHeight: 32)
                }
                .buttonStyle(.bordered)
                .disabled(isSubmitDisabled)
            }

            if case .failed(let message) = session.authPhase {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var buttonTitle: String {
        session.authPhase == .signingIn ? "Signing In..." : "Sign In"
    }

    private var isSubmitDisabled: Bool {
        session.authPhase == .signingIn || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty
    }
}

private struct BrowserAuthUnavailableView: View {
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("Backend Not Configured")
                .font(.system(size: 18, weight: .semibold))

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
