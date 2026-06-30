import Combine
import Foundation
import Security
import SwiftUI
import ConvexMobile

extension ConvexClient: @unchecked Sendable {}

enum BrowserAuthPhase: Equatable {
    case unavailable(String)
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
        internalDate.map(Date.init(timeIntervalSince1970:))
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
        startTimestamp.map(Date.init(timeIntervalSince1970:))
    }
}

@MainActor
final class BrowserSessionController: ObservableObject, BrowserCloudSynchronizing {
    @Published private(set) var authPhase: BrowserAuthPhase
    @Published private(set) var mailMessages: [BrowserMailMessage] = []
    @Published private(set) var calendars: [BrowserGoogleCalendar] = []
    @Published private(set) var calendarEvents: [BrowserCalendarEvent] = []
    @Published private(set) var googleConnectURL: URL?
    @Published private(set) var username: String?

    private let deploymentURL: String
    private let client: ConvexClient?
    private let tokenStore = BrowserSessionTokenStore()
    private var cancellables: Set<AnyCancellable> = []
    private var hasMigratedLocalState = false
    private var sessionToken: String?

    var isSignedIn: Bool {
        authPhase == .signedIn
    }

    init(deploymentURL: String = BrowserCloudConfiguration.convexDeploymentURL) {
        self.deploymentURL = deploymentURL
        guard !deploymentURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            authPhase = .unavailable("Set BROWSER_CONVEX_URL, CONVEX_URL, or BrowserConvexURL to your Convex deployment URL.")
            client = nil
            return
        }

        client = ConvexClient(deploymentUrl: deploymentURL)
        authPhase = .signedOut
    }

    func loginFromCache() {
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
            username = nil
            mailMessages = []
            calendars = []
            calendarEvents = []
            googleConnectURL = nil
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
        client.subscribe(
            to: "mail:messages",
            with: ["sessionToken": sessionToken, "limit": 100],
            yielding: [BrowserMailMessage].self
        )
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    if case .failure(let error) = completion {
                        NSLog("Convex mail subscription failed: \(error)")
                    }
                },
                receiveValue: { [weak self] messages in
                    self?.mailMessages = messages
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
            with: ["sessionToken": sessionToken, "limit": 200],
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
        if googleConnectURL == nil {
            prepareGoogleConnection()
        }

        guard let googleConnectURL else {
            return
        }

        NSWorkspace.shared.open(googleConnectURL)
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
        switch session.authPhase {
        case .signedIn:
            content()
        case .unavailable(let message):
            BrowserAuthUnavailableView(message: message)
        default:
            BrowserAuthView(session: session)
        }
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
        .onAppear {
            session.loginFromCache()
        }
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
