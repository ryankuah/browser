import Foundation

struct StoredBrowserSession: Sendable {
    let selectedTabID: UUID?
    let tabs: [StoredBrowserTab]
}

struct StoredBrowserTab: Sendable {
    let id: UUID
    let position: Int
    let title: String
    let url: URL?
}

struct BrowserTabSnapshot: Sendable {
    let id: UUID
    let position: Int
    let title: String
    let url: URL?
}

struct StoredBrowserProfile: Sendable {
    let id: UUID
    let name: String
    let colorHex: String
    let position: Int
}

struct StoredBrowserBookmark: Sendable {
    let id: UUID
    let position: Int
    let title: String
    let url: URL
}

struct StoredHistoryEntry: Sendable {
    let title: String
    let url: URL
    let lastVisitedAt: Date
    let visitCount: Int
    let faviconData: Data?
}

struct StoredHistoryVisit: Sendable, Identifiable {
    let id: Int64
    let title: String
    let url: URL
    let visitedAt: Date
    let faviconData: Data?
}

struct StoredHistoryTreeNode: Sendable, Identifiable {
    let id: Int64
    let journeyID: UUID
    let parentID: Int64?
    let title: String
    let url: URL
    let visitedAt: Date
    let faviconData: Data?
}

struct StoredAutocompleteSite: Sendable {
    let host: String
    let registrableDomain: String
    let subdomain: String?
    let title: String
    let url: URL
    let visitCount: Int
    let lastVisitedAt: Date
    let faviconData: Data?
}

struct StoredAutocompletePage: Sendable {
    let url: URL
    let title: String
    let host: String
    let registrableDomain: String
    let subdomain: String?
    let visitCount: Int
    let lastVisitedAt: Date
    let faviconData: Data?
}

struct StoredMediaPermissionDecision: Sendable {
    let origin: String
    let deviceKind: String
    let isAllowed: Bool
}

enum BrowserDatabaseError: LocalizedError {
    case openFailed(String)
    case sqliteFailure(String)
    case invalidApplicationSupportDirectory

    var errorDescription: String? {
        switch self {
        case .openFailed(let message), .sqliteFailure(let message):
            return message
        case .invalidApplicationSupportDirectory:
            return "Could not locate the Application Support directory."
        }
    }
}
