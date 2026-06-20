import Foundation

struct BrowserStartupData: Sendable {
    var settings: [String: String] = [:]
    var profiles: [StoredBrowserProfile] = []
    var activeProfileID: UUID?
    var mediaPermissionDecisions: [StoredMediaPermissionDecision] = []
    var bookmarks: [StoredBrowserBookmark] = []
    var autocompleteSites: [StoredAutocompleteSite] = []
    var autocompletePages: [StoredAutocompletePage] = []
    var downloads: [BrowserDownload] = []
    var session: StoredBrowserSession?
}

actor BrowserPersistenceStore {
    private var database: BrowserDatabase?
    private var didAttemptOpen = false

    func loadStartupData() -> BrowserStartupData {
        var data = BrowserStartupData()
        data.settings = load(default: [:]) { try $0.loadSettings() }
        data.profiles = load(default: []) { try $0.loadProfiles() }
        data.activeProfileID = load(default: UUID?.none) { try $0.loadActiveProfileID() }
        data.mediaPermissionDecisions = load(default: []) { try $0.loadMediaPermissionDecisions() }
        data.autocompleteSites = load(default: []) { try $0.loadAutocompleteSites(limit: 500) }
        data.autocompletePages = load(default: []) { try $0.loadAutocompletePages(limit: 1000) }
        data.downloads = load(default: []) { database in
            try Self.interruptActiveDownloads(database.loadRecentDownloads(limit: 50), database: database)
        }
        let selectedProfileID = Self.selectedProfileID(from: data.profiles, activeProfileID: data.activeProfileID)
        if let selectedProfileID {
            data.bookmarks = load(default: []) { try $0.loadBookmarks(profileID: selectedProfileID) }
            data.session = load(default: StoredBrowserSession?.none) { try $0.loadSession(profileID: selectedProfileID) }
        }
        return data
    }

    func loadProfileState(profileID: UUID) -> (bookmarks: [StoredBrowserBookmark], session: StoredBrowserSession?) {
        let bookmarks: [StoredBrowserBookmark] = load(default: []) { try $0.loadBookmarks(profileID: profileID) }
        let session: StoredBrowserSession? = load(default: nil) { try $0.loadSession(profileID: profileID) }
        return (bookmarks, session)
    }

    func saveSession(profileID: UUID, tabs: [BrowserTabSnapshot], selectedTabID: UUID?) {
        save("Browser session save failed") {
            try $0.saveSession(profileID: profileID, tabs: tabs, selectedTabID: selectedTabID)
        }
    }

    func saveSetting(key: String, value: String) {
        save("Browser setting save failed") {
            try $0.saveSetting(key: key, value: value)
        }
    }

    func saveMediaPermissionDecision(origin: String, deviceKind: String, isAllowed: Bool) {
        save("Browser media permission decision save failed") {
            try $0.saveMediaPermissionDecision(origin: origin, deviceKind: deviceKind, isAllowed: isAllowed)
        }
    }

    func saveDownload(_ download: BrowserDownload) {
        save("Browser download save failed") {
            try $0.saveDownload(download)
        }
    }

    func saveProfile(_ profile: StoredBrowserProfile) {
        save("Browser profile save failed") {
            try $0.saveProfile(profile)
        }
    }

    func deleteProfileAndReindex(id: UUID, activeProfileID: UUID?, remainingProfiles: [StoredBrowserProfile]) {
        save("Browser profile delete failed") {
            try $0.deleteProfileAndReindex(
                id: id,
                activeProfileID: activeProfileID,
                remainingProfiles: remainingProfiles
            )
        }
    }

    func setActiveProfileID(_ id: UUID) {
        saveSetting(key: "activeProfileID", value: id.uuidString)
    }

    func saveBookmark(_ bookmark: StoredBrowserBookmark, profileID: UUID) {
        save("Browser bookmark save failed") {
            try $0.saveBookmark(bookmark, profileID: profileID)
        }
    }

    func deleteBookmarkAndReindex(id: UUID, profileID: UUID, remainingBookmarks: [StoredBrowserBookmark]) {
        save("Browser bookmark delete failed") { database in
            try database.deleteBookmark(id: id)
            for bookmark in remainingBookmarks {
                try database.saveBookmark(bookmark, profileID: profileID)
            }
        }
    }

    func recordHistoryVisit(
        url: URL,
        title: String,
        tabID: UUID?,
        journeyID: UUID?,
        parentVisitID: Int64?
    ) -> Int64? {
        load(default: Int64?.none) { database in
            try database.recordHistoryVisit(
                url: url,
                title: title,
                tabID: tabID,
                journeyID: journeyID,
                parentVisitID: parentVisitID
            )
        }
    }

    func loadAutocompleteSites(limit: Int) -> [StoredAutocompleteSite] {
        load(default: []) { try $0.loadAutocompleteSites(limit: limit) }
    }

    func loadAutocompletePages(limit: Int) -> [StoredAutocompletePage] {
        load(default: []) { try $0.loadAutocompletePages(limit: limit) }
    }

    func saveFavicon(origin: String, pageURL: URL, imageData: Data) {
        save("Browser favicon save failed") {
            try $0.saveFavicon(origin: origin, pageURL: pageURL, imageData: imageData)
        }
    }

    func loadHistoryEntries(limit: Int) -> [StoredHistoryEntry] {
        load(default: []) { try $0.loadRecentHistoryEntries(limit: limit) }
    }

    func loadHistoryVisits(limit: Int) -> [StoredHistoryVisit] {
        load(default: []) { try $0.loadRecentHistoryVisits(limit: limit) }
    }

    func loadHistoryTreeNodes(limit: Int) -> [StoredHistoryTreeNode] {
        load(default: []) { try $0.loadRecentHistoryTreeNodes(limit: limit) }
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

    private func load<T>(default defaultValue: T, _ operation: (BrowserDatabase) throws -> T) -> T {
        guard let database = databaseIfAvailable() else {
            return defaultValue
        }

        do {
            return try operation(database)
        } catch {
            NSLog("Browser persistence load failed: \(error.localizedDescription)")
            return defaultValue
        }
    }

    private func save(_ failureMessage: String, operation: (BrowserDatabase) throws -> Void) {
        guard let database = databaseIfAvailable() else {
            return
        }

        do {
            try operation(database)
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
