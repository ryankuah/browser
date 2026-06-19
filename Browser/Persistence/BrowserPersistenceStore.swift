import Foundation

struct BrowserStartupData: Sendable {
    var settings: [String: String] = [:]
    var profiles: [StoredBrowserProfile] = []
    var activeProfileID: UUID?
    var mediaPermissionDecisions: [StoredMediaPermissionDecision] = []
    var bookmarks: [StoredBrowserBookmark] = []
    var historySuggestions: [StoredHistorySuggestion] = []
    var downloads: [BrowserDownload] = []
    var session: StoredBrowserSession?
}

actor BrowserPersistenceStore {
    private var database: BrowserDatabase?
    private var didAttemptOpen = false

    func loadStartupData() -> BrowserStartupData {
        guard let database = databaseIfAvailable() else {
            return BrowserStartupData()
        }

        var data = BrowserStartupData()
        data.settings = load { try database.loadSettings() } ?? [:]
        data.profiles = load { try database.loadProfiles() } ?? []
        data.activeProfileID = load { try database.loadActiveProfileID() } ?? nil
        data.mediaPermissionDecisions = load { try database.loadMediaPermissionDecisions() } ?? []
        data.historySuggestions = load { try database.loadRecentHistorySuggestions(limit: 80) } ?? []
        data.downloads = load { try Self.interruptActiveDownloads(database.loadRecentDownloads(limit: 50), database: database) } ?? []
        let selectedProfileID = Self.selectedProfileID(from: data.profiles, activeProfileID: data.activeProfileID)
        if let selectedProfileID {
            data.bookmarks = load { try database.loadBookmarks(profileID: selectedProfileID) } ?? []
            data.session = load { try database.loadSession(profileID: selectedProfileID) } ?? nil
        }
        return data
    }

    func loadProfileState(profileID: UUID) -> (bookmarks: [StoredBrowserBookmark], session: StoredBrowserSession?) {
        guard let database = databaseIfAvailable() else {
            return ([], nil)
        }

        let bookmarks = load { try database.loadBookmarks(profileID: profileID) } ?? []
        let session = load { try database.loadSession(profileID: profileID) } ?? nil
        return (bookmarks, session)
    }

    func saveSession(profileID: UUID, tabs: [BrowserTabSnapshot], selectedTabID: UUID?) {
        guard let database = databaseIfAvailable() else {
            return
        }

        save("Browser session save failed") {
            try database.saveSession(profileID: profileID, tabs: tabs, selectedTabID: selectedTabID)
        }
    }

    func saveSetting(key: String, value: String) {
        guard let database = databaseIfAvailable() else {
            return
        }

        save("Browser setting save failed") {
            try database.saveSetting(key: key, value: value)
        }
    }

    func saveMediaPermissionDecision(origin: String, deviceKind: String, isAllowed: Bool) {
        guard let database = databaseIfAvailable() else {
            return
        }

        save("Browser media permission decision save failed") {
            try database.saveMediaPermissionDecision(origin: origin, deviceKind: deviceKind, isAllowed: isAllowed)
        }
    }

    func saveDownload(_ download: BrowserDownload) {
        guard let database = databaseIfAvailable() else {
            return
        }

        save("Browser download save failed") {
            try database.saveDownload(download)
        }
    }

    func saveProfile(_ profile: StoredBrowserProfile) {
        guard let database = databaseIfAvailable() else {
            return
        }

        save("Browser profile save failed") {
            try database.saveProfile(profile)
        }
    }

    func setActiveProfileID(_ id: UUID) {
        saveSetting(key: "activeProfileID", value: id.uuidString)
    }

    func saveBookmark(_ bookmark: StoredBrowserBookmark, profileID: UUID) {
        guard let database = databaseIfAvailable() else {
            return
        }

        save("Browser bookmark save failed") {
            try database.saveBookmark(bookmark, profileID: profileID)
        }
    }

    func deleteBookmarkAndReindex(id: UUID, profileID: UUID, remainingBookmarks: [StoredBrowserBookmark]) {
        guard let database = databaseIfAvailable() else {
            return
        }

        save("Browser bookmark delete failed") {
            try database.deleteBookmark(id: id)
            for bookmark in remainingBookmarks {
                try database.saveBookmark(bookmark, profileID: profileID)
            }
        }
    }

    func recordHistoryVisitAndLoadSuggestions(url: URL, title: String, tabID: UUID?, limit: Int) -> [StoredHistorySuggestion] {
        guard let database = databaseIfAvailable() else {
            return []
        }

        return load {
            try database.recordHistoryVisit(url: url, title: title, tabID: tabID)
            return try database.loadRecentHistorySuggestions(limit: limit)
        } ?? []
    }

    func saveFaviconAndLoadSuggestions(origin: String, pageURL: URL, imageData: Data, limit: Int) -> [StoredHistorySuggestion] {
        guard let database = databaseIfAvailable() else {
            return []
        }

        return load {
            try database.saveFavicon(origin: origin, pageURL: pageURL, imageData: imageData)
            return try database.loadRecentHistorySuggestions(limit: limit)
        } ?? []
    }

    func loadHistorySuggestions(limit: Int) -> [StoredHistorySuggestion] {
        guard let database = databaseIfAvailable() else {
            return []
        }

        return load {
            try database.loadRecentHistorySuggestions(limit: limit)
        } ?? []
    }

    private func databaseIfAvailable() -> BrowserDatabase? {
        if didAttemptOpen {
            return database
        }

        didAttemptOpen = true
        do {
            database = try BrowserDatabase.openDefault()
        } catch {
            NSLog("Browser persistence disabled: \(error.localizedDescription)")
        }

        return database
    }

    private func load<T>(_ operation: () throws -> T) -> T? {
        do {
            return try operation()
        } catch {
            NSLog("Browser persistence load failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func save(_ failureMessage: String, operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            NSLog("\(failureMessage): \(error.localizedDescription)")
        }
    }

    private static func selectedProfileID(from profiles: [StoredBrowserProfile], activeProfileID: UUID?) -> UUID? {
        if let activeProfileID,
           profiles.contains(where: { $0.id == activeProfileID }) {
            return activeProfileID
        }

        return profiles.sorted { $0.position < $1.position }.first?.id
    }

    private static func interruptActiveDownloads(_ downloads: [BrowserDownload], database: BrowserDatabase) throws -> [BrowserDownload] {
        try downloads.map { download in
            guard download.status == .inProgress else {
                return download
            }

            var interruptedDownload = download
            interruptedDownload.status = .failed
            interruptedDownload.finishedAt = Date()
            interruptedDownload.errorMessage = "Interrupted"
            try database.saveDownload(interruptedDownload)
            return interruptedDownload
        }
    }
}
