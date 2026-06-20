import Foundation
import SQLite3

final class BrowserDatabase {
    private static let defaultSessionID = "default"

    private let db: OpaquePointer?

    static func openDefault() throws -> BrowserDatabase {
        let fileManager = FileManager.default
        guard let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw BrowserDatabaseError.invalidApplicationSupportDirectory
        }

        let bundleID = Bundle.main.bundleIdentifier ?? "com.ryankuah.browser"
        let databaseDirectory = supportDirectory.appendingPathComponent(bundleID, isDirectory: true)
        try fileManager.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)

        return try BrowserDatabase(url: databaseDirectory.appendingPathComponent("browser.sqlite"))
    }

    init(url: URL) throws {
        var connection: OpaquePointer?
        let flags = SQLite.openReadWrite | SQLite.openCreate | SQLite.openFullMutex
        let result = url.path.withCString { path in
            sqlite3_open_v2(path, &connection, flags, nil)
        }

        guard result == SQLite.ok, let connection else {
            let message = connection.map { SQLite.message(for: $0) } ?? "Unable to open SQLite database."
            if let connection {
                _ = sqlite3_close(connection)
            }
            throw BrowserDatabaseError.openFailed(message)
        }

        db = connection
        try configure()
        try migrateIfNeeded()
    }

    deinit {
        _ = sqlite3_close(db)
    }

    func loadProfiles() throws -> [StoredBrowserProfile] {
        try withStatement(
            """
            SELECT id, name, color_hex, position
            FROM profiles
            ORDER BY position ASC
            """
        ) { statement in
            var profiles: [StoredBrowserProfile] = []
            while try statement.step() == SQLite.row {
                guard let rawID = statement.text(at: 0),
                      let id = UUID(uuidString: rawID) else {
                    continue
                }

                profiles.append(
                    StoredBrowserProfile(
                        id: id,
                        name: statement.text(at: 1) ?? "Profile",
                        colorHex: statement.text(at: 2) ?? BrowserProfile.defaultColorHex,
                        position: Int(statement.int64(at: 3))
                    )
                )
            }

            return profiles
        }
    }

    func saveProfile(_ profile: StoredBrowserProfile) throws {
        try withStatement(
            """
            INSERT INTO profiles (id, name, color_hex, position, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                color_hex = excluded.color_hex,
                position = excluded.position,
                updated_at = excluded.updated_at
            """
        ) { statement in
            let now = Date().timeIntervalSince1970
            try statement.bind(profile.id.uuidString, at: 1)
            try statement.bind(profile.name, at: 2)
            try statement.bind(profile.colorHex, at: 3)
            try statement.bind(Int64(profile.position), at: 4)
            try statement.bind(now, at: 5)
            try statement.bind(now, at: 6)
            try statement.stepDone()
        }
    }

    func deleteProfileAndReindex(id: UUID, activeProfileID: UUID?, remainingProfiles: [StoredBrowserProfile]) throws {
        try transaction {
            try withStatement("DELETE FROM profiles WHERE id = ?") { statement in
                try statement.bind(id.uuidString, at: 1)
                try statement.stepDone()
            }

            try withStatement("DELETE FROM sessions WHERE id = ?") { statement in
                try statement.bind(id.uuidString, at: 1)
                try statement.stepDone()
            }

            for profile in remainingProfiles {
                try saveProfile(profile)
            }

            if let activeProfileID {
                try saveSetting(key: "activeProfileID", value: activeProfileID.uuidString)
            } else {
                try withStatement("DELETE FROM settings WHERE key = ?") { statement in
                    try statement.bind("activeProfileID", at: 1)
                    try statement.stepDone()
                }
            }
        }
    }

    func loadActiveProfileID() throws -> UUID? {
        let settings = try loadSettings()
        guard let rawID = settings["activeProfileID"] else {
            return nil
        }

        return UUID(uuidString: rawID)
    }

    func loadSession(profileID: UUID) throws -> StoredBrowserSession? {
        let selectedTabID = try loadSelectedTabID(sessionID: profileID.uuidString)
        let tabs = try loadTabs(sessionID: profileID.uuidString)

        guard selectedTabID != nil || !tabs.isEmpty else {
            return nil
        }

        return StoredBrowserSession(selectedTabID: selectedTabID, tabs: tabs)
    }

    func saveSession(profileID: UUID, tabs: [BrowserTabSnapshot], selectedTabID: UUID?) throws {
        try transaction {
            let now = Date().timeIntervalSince1970
            let sessionID = profileID.uuidString

            try withStatement(
                """
                INSERT INTO sessions (id, selected_tab_id, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    selected_tab_id = excluded.selected_tab_id,
                    updated_at = excluded.updated_at
                """
            ) { statement in
                try statement.bind(sessionID, at: 1)
                try statement.bind(selectedTabID?.uuidString, at: 2)
                try statement.bind(now, at: 3)
                try statement.stepDone()
            }

            try withStatement("DELETE FROM tabs WHERE session_id = ?") { statement in
                try statement.bind(sessionID, at: 1)
                try statement.stepDone()
            }

            for tab in tabs {
                try withStatement(
                    """
                    INSERT INTO tabs (id, session_id, position, title, url, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """
                ) { statement in
                    try statement.bind(tab.id.uuidString, at: 1)
                    try statement.bind(sessionID, at: 2)
                    try statement.bind(Int64(tab.position), at: 3)
                    try statement.bind(tab.title, at: 4)
                    try statement.bind(tab.url?.absoluteString, at: 5)
                    try statement.bind(now, at: 6)
                    try statement.bind(now, at: 7)
                    try statement.stepDone()
                }
            }
        }
    }

    func recordHistoryVisit(url: URL, title: String, tabID: UUID?, journeyID: UUID?, parentVisitID: Int64?) throws -> Int64 {
        var historyVisitID: Int64 = 0

        try transaction {
            let visitedAt = Date().timeIntervalSince1970
            let origin = BrowserNavigation.originKey(for: url)
            let resolvedParentVisitID = try resolvedHistoryParentVisitID(
                parentVisitID,
                tabID: tabID,
                journeyID: journeyID
            )
            try withStatement(
                """
                INSERT INTO history_visits (url, title, tab_id, visited_at, origin, history_journey_id, history_parent_visit_id)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """
            ) { statement in
                try statement.bind(url.absoluteString, at: 1)
                try statement.bind(title, at: 2)
                try statement.bind(tabID?.uuidString, at: 3)
                try statement.bind(visitedAt, at: 4)
                try statement.bind(origin, at: 5)
                try statement.bind(journeyID?.uuidString, at: 6)
                try statement.bind(resolvedParentVisitID, at: 7)
                try statement.stepDone()
            }

            historyVisitID = sqlite3_last_insert_rowid(db)
            try recordAutocompleteVisit(url: url, title: title, visitedAt: visitedAt)
        }

        return historyVisitID
    }

    private func resolvedHistoryParentVisitID(_ parentVisitID: Int64?, tabID: UUID?, journeyID: UUID?) throws -> Int64? {
        guard let journeyID else {
            return nil
        }

        if let parentVisitID,
           try isHistoryParentVisitID(parentVisitID, in: journeyID) {
            return parentVisitID
        }

        guard let tabID else {
            return nil
        }

        return try latestHistoryVisitID(tabID: tabID, journeyID: journeyID)
    }

    private func isHistoryParentVisitID(_ parentVisitID: Int64, in journeyID: UUID) throws -> Bool {
        try withStatement(
            """
            SELECT 1
            FROM history_visits
            WHERE id = ?
              AND history_journey_id = ?
            LIMIT 1
            """
        ) { statement in
            try statement.bind(parentVisitID, at: 1)
            try statement.bind(journeyID.uuidString, at: 2)
            return try statement.step() == SQLite.row
        }
    }

    private func latestHistoryVisitID(tabID: UUID, journeyID: UUID) throws -> Int64? {
        return try withStatement(
            """
            SELECT id
            FROM history_visits
            WHERE tab_id = ?
              AND history_journey_id = ?
            ORDER BY visited_at DESC, id DESC
            LIMIT 1
            """
        ) { statement in
            try statement.bind(tabID.uuidString, at: 1)
            try statement.bind(journeyID.uuidString, at: 2)
            return try statement.step() == SQLite.row ? statement.int64(at: 0) : nil
        }
    }

    func loadRecentHistoryEntries(limit: Int) throws -> [StoredHistoryEntry] {
        try withStatement(
            """
            SELECT history_visits.url, history_visits.title, latest_visits.latest_visit, latest_visits.visit_count, favicons.image_data
            FROM history_visits
            INNER JOIN (
                SELECT url, MAX(visited_at) AS latest_visit, COUNT(*) AS visit_count
                FROM history_visits
                GROUP BY url
            ) latest_visits
                ON latest_visits.url = history_visits.url
                AND latest_visits.latest_visit = history_visits.visited_at
            LEFT JOIN favicons
                ON favicons.origin = history_visits.origin
            GROUP BY history_visits.url
            ORDER BY latest_visits.latest_visit DESC
            LIMIT ?
            """
        ) { statement in
            try statement.bind(Int64(limit), at: 1)

            var entries: [StoredHistoryEntry] = []
            while try statement.step() == SQLite.row {
                guard let rawURL = statement.text(at: 0),
                      let url = URL(string: rawURL) else {
                    continue
                }

                entries.append(
                    StoredHistoryEntry(
                        title: statement.text(at: 1) ?? url.host() ?? rawURL,
                        url: url,
                        lastVisitedAt: Date(timeIntervalSince1970: statement.double(at: 2)),
                        visitCount: Int(statement.int64(at: 3)),
                        faviconData: statement.data(at: 4)
                    )
                )
            }

            return entries
        }
    }

    func loadRecentHistoryVisits(limit: Int) throws -> [StoredHistoryVisit] {
        try withStatement(
            """
            SELECT history_visits.id, history_visits.title, history_visits.url, history_visits.visited_at, favicons.image_data
            FROM history_visits
            LEFT JOIN favicons
                ON favicons.origin = history_visits.origin
            ORDER BY history_visits.visited_at DESC, history_visits.id DESC
            LIMIT ?
            """
        ) { statement in
            try statement.bind(Int64(limit), at: 1)

            var visits: [StoredHistoryVisit] = []
            while try statement.step() == SQLite.row {
                guard let rawURL = statement.text(at: 2),
                      let url = URL(string: rawURL) else {
                    continue
                }

                visits.append(
                    StoredHistoryVisit(
                        id: statement.int64(at: 0),
                        title: statement.text(at: 1) ?? url.host() ?? rawURL,
                        url: url,
                        visitedAt: Date(timeIntervalSince1970: statement.double(at: 3)),
                        faviconData: statement.data(at: 4)
                    )
                )
            }

            return visits
        }
    }

    func loadRecentHistoryTreeNodes(limit: Int) throws -> [StoredHistoryTreeNode] {
        try withStatement(
            """
            WITH recent_journeys AS (
                SELECT history_journey_id, MAX(visited_at) AS latest_visit
                FROM history_visits
                WHERE history_journey_id IS NOT NULL
                GROUP BY history_journey_id
                ORDER BY latest_visit DESC
                LIMIT ?
            )
            SELECT history_visits.id,
                   history_visits.history_journey_id,
                   history_visits.history_parent_visit_id,
                   history_visits.title,
                   history_visits.url,
                   history_visits.visited_at,
                   favicons.image_data
            FROM history_visits
            INNER JOIN recent_journeys
                ON recent_journeys.history_journey_id = history_visits.history_journey_id
            LEFT JOIN favicons
                ON favicons.origin = history_visits.origin
            WHERE history_visits.history_journey_id IS NOT NULL
            ORDER BY recent_journeys.latest_visit DESC, history_visits.visited_at ASC
            """
        ) { statement in
            try statement.bind(Int64(limit), at: 1)

            var nodes: [StoredHistoryTreeNode] = []
            while try statement.step() == SQLite.row {
                guard let rawJourneyID = statement.text(at: 1),
                      let journeyID = UUID(uuidString: rawJourneyID),
                      let rawURL = statement.text(at: 4),
                      let url = URL(string: rawURL) else {
                    continue
                }

                nodes.append(
                    StoredHistoryTreeNode(
                        id: statement.int64(at: 0),
                        journeyID: journeyID,
                        parentID: statement.optionalInt64(at: 2),
                        title: statement.text(at: 3) ?? url.host() ?? rawURL,
                        url: url,
                        visitedAt: Date(timeIntervalSince1970: statement.double(at: 5)),
                        faviconData: statement.data(at: 6)
                    )
                )
            }

            return nodes
        }
    }

    func loadAutocompleteSites(limit: Int) throws -> [StoredAutocompleteSite] {
        try withStatement(
            """
            SELECT site_visit_frequencies.host,
                   site_visit_frequencies.registrable_domain,
                   site_visit_frequencies.subdomain,
                   site_visit_frequencies.title,
                   site_visit_frequencies.url,
                   site_visit_frequencies.visit_count,
                   site_visit_frequencies.last_visited_at,
                   favicons.image_data
            FROM site_visit_frequencies
            LEFT JOIN favicons
                ON favicons.origin = 'https://' || site_visit_frequencies.host
                OR favicons.origin = 'http://' || site_visit_frequencies.host
            ORDER BY site_visit_frequencies.visit_count DESC,
                     site_visit_frequencies.last_visited_at DESC
            LIMIT ?
            """
        ) { statement in
            try statement.bind(Int64(limit), at: 1)

            var sites: [StoredAutocompleteSite] = []
            while try statement.step() == SQLite.row {
                guard let host = statement.text(at: 0),
                      let registrableDomain = statement.text(at: 1),
                      let rawURL = statement.text(at: 4),
                      let url = URL(string: rawURL) else {
                    continue
                }

                sites.append(StoredAutocompleteSite(
                    host: host,
                    registrableDomain: registrableDomain,
                    subdomain: statement.text(at: 2),
                    title: statement.text(at: 3) ?? host,
                    url: url,
                    visitCount: Int(statement.int64(at: 5)),
                    lastVisitedAt: Date(timeIntervalSince1970: statement.double(at: 6)),
                    faviconData: statement.data(at: 7)
                ))
            }

            return sites
        }
    }

    func loadAutocompletePages(limit: Int) throws -> [StoredAutocompletePage] {
        try withStatement(
            """
            SELECT page_visit_frequencies.url,
                   page_visit_frequencies.title,
                   page_visit_frequencies.host,
                   page_visit_frequencies.registrable_domain,
                   page_visit_frequencies.subdomain,
                   page_visit_frequencies.visit_count,
                   page_visit_frequencies.last_visited_at,
                   favicons.image_data
            FROM page_visit_frequencies
            LEFT JOIN favicons
                ON favicons.origin = 'https://' || page_visit_frequencies.host
                OR favicons.origin = 'http://' || page_visit_frequencies.host
            ORDER BY page_visit_frequencies.visit_count DESC,
                     page_visit_frequencies.last_visited_at DESC
            LIMIT ?
            """
        ) { statement in
            try statement.bind(Int64(limit), at: 1)

            var pages: [StoredAutocompletePage] = []
            while try statement.step() == SQLite.row {
                guard let rawURL = statement.text(at: 0),
                      let url = URL(string: rawURL),
                      let host = statement.text(at: 2),
                      let registrableDomain = statement.text(at: 3) else {
                    continue
                }

                pages.append(StoredAutocompletePage(
                    url: url,
                    title: statement.text(at: 1) ?? url.host() ?? rawURL,
                    host: host,
                    registrableDomain: registrableDomain,
                    subdomain: statement.text(at: 4),
                    visitCount: Int(statement.int64(at: 5)),
                    lastVisitedAt: Date(timeIntervalSince1970: statement.double(at: 6)),
                    faviconData: statement.data(at: 7)
                ))
            }

            return pages
        }
    }

    func saveFavicon(origin: String, pageURL: URL, imageData: Data) throws {
        try withStatement(
            """
            INSERT INTO favicons (origin, page_url, image_data, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(origin) DO UPDATE SET
                page_url = excluded.page_url,
                image_data = excluded.image_data,
                updated_at = excluded.updated_at
            """
        ) { statement in
            try statement.bind(origin, at: 1)
            try statement.bind(pageURL.absoluteString, at: 2)
            try statement.bind(imageData, at: 3)
            try statement.bind(Date().timeIntervalSince1970, at: 4)
            try statement.stepDone()
        }
    }

    private static func autocompleteHostParts(for url: URL) -> (host: String, registrableDomain: String, subdomain: String?)? {
        guard let rawHost = url.host()?.lowercased() else {
            return nil
        }

        let host = rawHost.removingWWWPrefix
        let parts = host.split(separator: ".").map(String.init)
        guard parts.count >= 2 else {
            return host == "localhost" ? (host, host, nil) : nil
        }

        let registrableDomain = parts.suffix(2).joined(separator: ".")
        let subdomainParts = parts.dropLast(2)
        let subdomain = subdomainParts.isEmpty ? nil : subdomainParts.joined(separator: ".")
        return (host, registrableDomain, subdomain)
    }

    private static func siteURLString(for url: URL, host: String) -> String {
        let scheme = url.scheme?.lowercased() ?? "https"
        return "\(scheme)://\(host)"
    }

    func loadBookmarks(profileID: UUID) throws -> [StoredBrowserBookmark] {
        try withStatement(
            """
            SELECT id, position, title, url
            FROM bookmarks
            WHERE profile_id = ?
            ORDER BY position ASC
            """
        ) { statement in
            try statement.bind(profileID.uuidString, at: 1)

            var bookmarks: [StoredBrowserBookmark] = []
            while try statement.step() == SQLite.row {
                guard let rawID = statement.text(at: 0),
                      let id = UUID(uuidString: rawID),
                      let rawURL = statement.text(at: 3),
                      let url = URL(string: rawURL) else {
                    continue
                }

                bookmarks.append(
                    StoredBrowserBookmark(
                        id: id,
                        position: Int(statement.int64(at: 1)),
                        title: statement.text(at: 2) ?? url.host() ?? rawURL,
                        url: url
                    )
                )
            }

            return bookmarks
        }
    }

    func saveBookmark(_ bookmark: StoredBrowserBookmark, profileID: UUID) throws {
        try withStatement(
            """
            INSERT INTO bookmarks (id, profile_id, position, title, url, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                profile_id = excluded.profile_id,
                position = excluded.position,
                title = excluded.title,
                url = excluded.url,
                updated_at = excluded.updated_at
            """
        ) { statement in
            let now = Date().timeIntervalSince1970
            try statement.bind(bookmark.id.uuidString, at: 1)
            try statement.bind(profileID.uuidString, at: 2)
            try statement.bind(Int64(bookmark.position), at: 3)
            try statement.bind(bookmark.title, at: 4)
            try statement.bind(bookmark.url.absoluteString, at: 5)
            try statement.bind(now, at: 6)
            try statement.bind(now, at: 7)
            try statement.stepDone()
        }
    }

    func deleteBookmark(id: UUID) throws {
        try withStatement("DELETE FROM bookmarks WHERE id = ?") { statement in
            try statement.bind(id.uuidString, at: 1)
            try statement.stepDone()
        }
    }

    func loadSettings() throws -> [String: String] {
        try withStatement("SELECT key, value FROM settings") { statement in
            var settings: [String: String] = [:]
            while try statement.step() == SQLite.row {
                guard let key = statement.text(at: 0),
                      let value = statement.text(at: 1) else {
                    continue
                }

                settings[key] = value
            }

            return settings
        }
    }

    func saveSetting(key: String, value: String) throws {
        try withStatement(
            """
            INSERT INTO settings (key, value, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                value = excluded.value,
                updated_at = excluded.updated_at
            """
        ) { statement in
            try statement.bind(key, at: 1)
            try statement.bind(value, at: 2)
            try statement.bind(Date().timeIntervalSince1970, at: 3)
            try statement.stepDone()
        }
    }

    func loadMediaPermissionDecisions() throws -> [StoredMediaPermissionDecision] {
        try withStatement(
            """
            SELECT origin, device_kind, is_allowed
            FROM media_permissions
            """
        ) { statement in
            var decisions: [StoredMediaPermissionDecision] = []
            while try statement.step() == SQLite.row {
                guard let origin = statement.text(at: 0),
                      let deviceKind = statement.text(at: 1) else {
                    continue
                }

                decisions.append(StoredMediaPermissionDecision(
                    origin: origin,
                    deviceKind: deviceKind,
                    isAllowed: statement.int64(at: 2) != 0
                ))
            }

            return decisions
        }
    }

    func saveMediaPermissionDecision(origin: String, deviceKind: String, isAllowed: Bool) throws {
        try withStatement(
            """
            INSERT INTO media_permissions (origin, device_kind, is_allowed, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(origin, device_kind) DO UPDATE SET
                is_allowed = excluded.is_allowed,
                updated_at = excluded.updated_at
            """
        ) { statement in
            try statement.bind(origin, at: 1)
            try statement.bind(deviceKind, at: 2)
            try statement.bind(isAllowed ? Int64(1) : Int64(0), at: 3)
            try statement.bind(Date().timeIntervalSince1970, at: 4)
            try statement.stepDone()
        }
    }

    func loadRecentDownloads(limit: Int) throws -> [BrowserDownload] {
        try withStatement(
            """
            SELECT id, source_url, destination_url, suggested_filename, received_bytes, expected_bytes, started_at, finished_at, status, error_message
            FROM downloads
            ORDER BY started_at DESC
            LIMIT ?
            """
        ) { statement in
            try statement.bind(Int64(limit), at: 1)

            var downloads: [BrowserDownload] = []
            while try statement.step() == SQLite.row {
                guard let rawID = statement.text(at: 0),
                      let id = UUID(uuidString: rawID) else {
                    continue
                }

                let rawSourceURL = statement.text(at: 1)
                let rawDestinationURL = statement.text(at: 2)
                let rawStatus = statement.text(at: 8) ?? BrowserDownloadStatus.failed.storageValue

                downloads.append(
                    BrowserDownload(
                        id: id,
                        sourceURL: rawSourceURL.flatMap(URL.init(string:)),
                        destinationURL: rawDestinationURL.map(URL.init(fileURLWithPath:)),
                        suggestedFilename: statement.text(at: 3) ?? "Download",
                        receivedBytes: statement.int64(at: 4),
                        expectedBytes: statement.optionalInt64(at: 5),
                        startedAt: Date(timeIntervalSince1970: statement.double(at: 6)),
                        finishedAt: statement.optionalDouble(at: 7).map(Date.init(timeIntervalSince1970:)),
                        status: BrowserDownloadStatus(storageValue: rawStatus),
                        errorMessage: statement.text(at: 9)
                    )
                )
            }

            return downloads
        }
    }

    func saveDownload(_ download: BrowserDownload) throws {
        try withStatement(
            """
            INSERT INTO downloads (
                id,
                source_url,
                destination_url,
                suggested_filename,
                received_bytes,
                expected_bytes,
                started_at,
                finished_at,
                status,
                error_message
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                source_url = excluded.source_url,
                destination_url = excluded.destination_url,
                suggested_filename = excluded.suggested_filename,
                received_bytes = excluded.received_bytes,
                expected_bytes = excluded.expected_bytes,
                started_at = excluded.started_at,
                finished_at = excluded.finished_at,
                status = excluded.status,
                error_message = excluded.error_message
            """
        ) { statement in
            try statement.bind(download.id.uuidString, at: 1)
            try statement.bind(download.sourceURL?.absoluteString, at: 2)
            try statement.bind(download.destinationURL?.path, at: 3)
            try statement.bind(download.suggestedFilename, at: 4)
            try statement.bind(download.receivedBytes, at: 5)
            try statement.bind(download.expectedBytes, at: 6)
            try statement.bind(download.startedAt.timeIntervalSince1970, at: 7)
            try statement.bind(download.finishedAt?.timeIntervalSince1970, at: 8)
            try statement.bind(download.status.storageValue, at: 9)
            try statement.bind(download.errorMessage, at: 10)
            try statement.stepDone()
        }
    }

    private func configure() throws {
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA busy_timeout = 5000")
        try execute("PRAGMA journal_mode = WAL")
    }

    private func migrateIfNeeded() throws {
        let version = try userVersion()

        if version < 1 {
            try transaction {
                try execute(
                    """
                    CREATE TABLE IF NOT EXISTS sessions (
                        id TEXT PRIMARY KEY,
                        selected_tab_id TEXT,
                        updated_at REAL NOT NULL
                    )
                    """
                )

                try execute(
                    """
                    CREATE TABLE IF NOT EXISTS tabs (
                        id TEXT PRIMARY KEY,
                        session_id TEXT NOT NULL,
                        position INTEGER NOT NULL,
                        title TEXT NOT NULL,
                        url TEXT,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL,
                        FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
                    )
                    """
                )

                try execute("CREATE INDEX IF NOT EXISTS tabs_session_position_idx ON tabs(session_id, position)")

                try execute(
                    """
                    CREATE TABLE IF NOT EXISTS history_visits (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        url TEXT NOT NULL,
                        title TEXT NOT NULL,
                        tab_id TEXT,
                        visited_at REAL NOT NULL
                    )
                    """
                )

                try execute("CREATE INDEX IF NOT EXISTS history_visits_visited_at_idx ON history_visits(visited_at DESC)")
                try execute("PRAGMA user_version = 1")
            }
        }

        if version < 2 {
            try transaction {
                try execute(
                    """
                    CREATE TABLE IF NOT EXISTS downloads (
                        id TEXT PRIMARY KEY,
                        source_url TEXT,
                        destination_url TEXT,
                        suggested_filename TEXT NOT NULL,
                        received_bytes INTEGER NOT NULL DEFAULT 0,
                        expected_bytes INTEGER,
                        started_at REAL NOT NULL,
                        finished_at REAL,
                        status TEXT NOT NULL,
                        error_message TEXT
                    )
                    """
                )

                try execute("CREATE INDEX IF NOT EXISTS downloads_started_at_idx ON downloads(started_at DESC)")
                try execute("PRAGMA user_version = 2")
            }
        }

        if version < 3 {
            try transaction {
                try execute(
                    """
                    CREATE TABLE IF NOT EXISTS bookmarks (
                        id TEXT PRIMARY KEY,
                        position INTEGER NOT NULL,
                        title TEXT NOT NULL,
                        url TEXT NOT NULL UNIQUE,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL
                    )
                    """
                )

                try execute("CREATE INDEX IF NOT EXISTS bookmarks_position_idx ON bookmarks(position)")
                try execute("PRAGMA user_version = 3")
            }
        }

        if version < 4 {
            try transaction {
                try execute(
                    """
                    CREATE TABLE IF NOT EXISTS settings (
                        key TEXT PRIMARY KEY,
                        value TEXT NOT NULL,
                        updated_at REAL NOT NULL
                    )
                    """
                )

                try execute(
                    """
                    CREATE TABLE IF NOT EXISTS media_permissions (
                        origin TEXT NOT NULL,
                        device_kind TEXT NOT NULL,
                        is_allowed INTEGER NOT NULL,
                        updated_at REAL NOT NULL,
                        PRIMARY KEY(origin, device_kind)
                    )
                    """
                )

                try execute("CREATE INDEX IF NOT EXISTS media_permissions_origin_idx ON media_permissions(origin)")
                try execute("PRAGMA user_version = 4")
            }
        }

        if version < 5 {
            try transaction {
                let historyColumns = try columns(in: "history_visits")
                if !historyColumns.contains("origin") {
                    try execute("ALTER TABLE history_visits ADD COLUMN origin TEXT")
                }

                try backfillHistoryVisitOrigins()
                try execute("CREATE INDEX IF NOT EXISTS history_visits_origin_idx ON history_visits(origin)")

                try execute(
                    """
                    CREATE TABLE IF NOT EXISTS favicons (
                        origin TEXT PRIMARY KEY,
                        page_url TEXT NOT NULL,
                        image_data BLOB NOT NULL,
                        updated_at REAL NOT NULL
                    )
                    """
                )

                try execute("PRAGMA user_version = 5")
            }
        }

        if version < 6 {
            try transaction {
                try execute(
                    """
                    CREATE TABLE IF NOT EXISTS profiles (
                        id TEXT PRIMARY KEY,
                        name TEXT NOT NULL,
                        color_hex TEXT NOT NULL,
                        position INTEGER NOT NULL,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL
                    )
                    """
                )

                try execute("CREATE INDEX IF NOT EXISTS profiles_position_idx ON profiles(position)")

                let legacyTabCount = try countRows(in: "tabs")
                let legacyBookmarkCount = try countRows(in: "bookmarks")
                let importedProfileID = UUID()

                if legacyTabCount > 0 || legacyBookmarkCount > 0 {
                    let now = Date().timeIntervalSince1970
                    try withStatement(
                        """
                        INSERT INTO profiles (id, name, color_hex, position, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """
                    ) { statement in
                        try statement.bind(importedProfileID.uuidString, at: 1)
                        try statement.bind("Personal", at: 2)
                        try statement.bind(BrowserProfile.defaultColorHex, at: 3)
                        try statement.bind(Int64(0), at: 4)
                        try statement.bind(now, at: 5)
                        try statement.bind(now, at: 6)
                        try statement.stepDone()
                    }

                    try withStatement(
                        """
                        INSERT INTO settings (key, value, updated_at)
                        VALUES (?, ?, ?)
                        ON CONFLICT(key) DO UPDATE SET
                            value = excluded.value,
                            updated_at = excluded.updated_at
                        """
                    ) { statement in
                        try statement.bind("activeProfileID", at: 1)
                        try statement.bind(importedProfileID.uuidString, at: 2)
                        try statement.bind(now, at: 3)
                        try statement.stepDone()
                    }

                    try withStatement(
                        """
                        INSERT INTO sessions (id, selected_tab_id, updated_at)
                        SELECT ?, selected_tab_id, updated_at
                        FROM sessions
                        WHERE id = ?
                        ON CONFLICT(id) DO NOTHING
                        """
                    ) { statement in
                        try statement.bind(importedProfileID.uuidString, at: 1)
                        try statement.bind(Self.defaultSessionID, at: 2)
                        try statement.stepDone()
                    }

                    try withStatement("UPDATE tabs SET session_id = ? WHERE session_id = ?") { statement in
                        try statement.bind(importedProfileID.uuidString, at: 1)
                        try statement.bind(Self.defaultSessionID, at: 2)
                        try statement.stepDone()
                    }

                    try withStatement("DELETE FROM sessions WHERE id = ?") { statement in
                        try statement.bind(Self.defaultSessionID, at: 1)
                        try statement.stepDone()
                    }
                }

                try execute(
                    """
                    CREATE TABLE bookmarks_v6 (
                        id TEXT PRIMARY KEY,
                        profile_id TEXT NOT NULL,
                        position INTEGER NOT NULL,
                        title TEXT NOT NULL,
                        url TEXT NOT NULL,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL,
                        FOREIGN KEY(profile_id) REFERENCES profiles(id) ON DELETE CASCADE,
                        UNIQUE(profile_id, url)
                    )
                    """
                )

                if legacyBookmarkCount > 0 {
                    try withStatement(
                        """
                        INSERT INTO bookmarks_v6 (id, profile_id, position, title, url, created_at, updated_at)
                        SELECT id, ?, position, title, url, created_at, updated_at
                        FROM bookmarks
                        """
                    ) { statement in
                        try statement.bind(importedProfileID.uuidString, at: 1)
                        try statement.stepDone()
                    }
                }

                try execute("DROP TABLE bookmarks")
                try execute("ALTER TABLE bookmarks_v6 RENAME TO bookmarks")
                try execute("CREATE INDEX IF NOT EXISTS bookmarks_profile_position_idx ON bookmarks(profile_id, position)")
                try execute("PRAGMA user_version = 6")
            }
        }

        if version < 7 {
            try transaction {
                try createAutocompleteFrequencyTables()
                try backfillAutocompleteFrequencies()
                try execute("PRAGMA user_version = 7")
            }
        }

        if version < 8 {
            try transaction {
                let historyColumns = try columns(in: "history_visits")
                if !historyColumns.contains("history_journey_id") {
                    try execute("ALTER TABLE history_visits ADD COLUMN history_journey_id TEXT")
                }
                if !historyColumns.contains("history_parent_visit_id") {
                    try execute("ALTER TABLE history_visits ADD COLUMN history_parent_visit_id INTEGER")
                }

                try execute("CREATE INDEX IF NOT EXISTS history_visits_journey_idx ON history_visits(history_journey_id, visited_at DESC)")
                try execute("CREATE INDEX IF NOT EXISTS history_visits_parent_idx ON history_visits(history_parent_visit_id)")
                try execute("PRAGMA user_version = 8")
            }
        }
    }

    private func createAutocompleteFrequencyTables() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS site_visit_frequencies (
                host TEXT PRIMARY KEY,
                registrable_domain TEXT NOT NULL,
                subdomain TEXT,
                title TEXT NOT NULL,
                url TEXT NOT NULL,
                visit_count INTEGER NOT NULL,
                last_visited_at REAL NOT NULL
            )
            """
        )
        try execute("CREATE INDEX IF NOT EXISTS site_visit_frequencies_registrable_idx ON site_visit_frequencies(registrable_domain)")
        try execute("CREATE INDEX IF NOT EXISTS site_visit_frequencies_subdomain_idx ON site_visit_frequencies(subdomain)")
        try execute("CREATE INDEX IF NOT EXISTS site_visit_frequencies_count_idx ON site_visit_frequencies(visit_count DESC, last_visited_at DESC)")

        try execute(
            """
            CREATE TABLE IF NOT EXISTS page_visit_frequencies (
                url TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                host TEXT NOT NULL,
                registrable_domain TEXT NOT NULL,
                subdomain TEXT,
                visit_count INTEGER NOT NULL,
                last_visited_at REAL NOT NULL
            )
            """
        )
        try execute("CREATE INDEX IF NOT EXISTS page_visit_frequencies_host_idx ON page_visit_frequencies(host)")
        try execute("CREATE INDEX IF NOT EXISTS page_visit_frequencies_registrable_idx ON page_visit_frequencies(registrable_domain)")
        try execute("CREATE INDEX IF NOT EXISTS page_visit_frequencies_count_idx ON page_visit_frequencies(visit_count DESC, last_visited_at DESC)")
    }

    private func recordAutocompleteVisit(url: URL, title: String, visitedAt: Double) throws {
        guard let parts = Self.autocompleteHostParts(for: url) else {
            return
        }

        try withStatement(
            """
            INSERT INTO site_visit_frequencies (
                host,
                registrable_domain,
                subdomain,
                title,
                url,
                visit_count,
                last_visited_at
            )
            VALUES (?, ?, ?, ?, ?, 1, ?)
            ON CONFLICT(host) DO UPDATE SET
                registrable_domain = excluded.registrable_domain,
                subdomain = excluded.subdomain,
                title = excluded.title,
                url = excluded.url,
                visit_count = site_visit_frequencies.visit_count + 1,
                last_visited_at = excluded.last_visited_at
            """
        ) { statement in
            try statement.bind(parts.host, at: 1)
            try statement.bind(parts.registrableDomain, at: 2)
            try statement.bind(parts.subdomain, at: 3)
            try statement.bind(title, at: 4)
            try statement.bind(Self.siteURLString(for: url, host: parts.host), at: 5)
            try statement.bind(visitedAt, at: 6)
            try statement.stepDone()
        }

        try withStatement(
            """
            INSERT INTO page_visit_frequencies (
                url,
                title,
                host,
                registrable_domain,
                subdomain,
                visit_count,
                last_visited_at
            )
            VALUES (?, ?, ?, ?, ?, 1, ?)
            ON CONFLICT(url) DO UPDATE SET
                title = excluded.title,
                host = excluded.host,
                registrable_domain = excluded.registrable_domain,
                subdomain = excluded.subdomain,
                visit_count = page_visit_frequencies.visit_count + 1,
                last_visited_at = excluded.last_visited_at
            """
        ) { statement in
            try statement.bind(url.absoluteString, at: 1)
            try statement.bind(title, at: 2)
            try statement.bind(parts.host, at: 3)
            try statement.bind(parts.registrableDomain, at: 4)
            try statement.bind(parts.subdomain, at: 5)
            try statement.bind(visitedAt, at: 6)
            try statement.stepDone()
        }
    }

    private func backfillAutocompleteFrequencies() throws {
        try withStatement(
            """
            SELECT url, title, visited_at
            FROM history_visits
            ORDER BY visited_at ASC
            """
        ) { statement in
            while try statement.step() == SQLite.row {
                guard let rawURL = statement.text(at: 0),
                      let url = URL(string: rawURL) else {
                    continue
                }

                try recordAutocompleteVisit(
                    url: url,
                    title: statement.text(at: 1) ?? url.host() ?? rawURL,
                    visitedAt: statement.double(at: 2)
                )
            }
        }
    }

    private func backfillHistoryVisitOrigins() throws {
        let visits = try withStatement("SELECT id, url FROM history_visits WHERE origin IS NULL") { statement in
            var visits: [(id: Int64, origin: String)] = []
            while try statement.step() == SQLite.row {
                guard let rawURL = statement.text(at: 1),
                      let url = URL(string: rawURL),
                      let origin = BrowserNavigation.originKey(for: url) else {
                    continue
                }

                visits.append((id: statement.int64(at: 0), origin: origin))
            }
            return visits
        }

        for visit in visits {
            try withStatement("UPDATE history_visits SET origin = ? WHERE id = ?") { statement in
                try statement.bind(visit.origin, at: 1)
                try statement.bind(visit.id, at: 2)
                try statement.stepDone()
            }
        }
    }

    private func columns(in tableName: String) throws -> Set<String> {
        try withStatement("PRAGMA table_info(\(tableName))") { statement in
            var columns = Set<String>()
            while try statement.step() == SQLite.row {
                if let name = statement.text(at: 1) {
                    columns.insert(name)
                }
            }
            return columns
        }
    }

    private func countRows(in tableName: String) throws -> Int {
        try withStatement("SELECT COUNT(*) FROM \(tableName)") { statement in
            guard try statement.step() == SQLite.row else {
                return 0
            }

            return Int(statement.int64(at: 0))
        }
    }

    private func loadSelectedTabID(sessionID: String) throws -> UUID? {
        try withStatement("SELECT selected_tab_id FROM sessions WHERE id = ?") { statement in
            try statement.bind(sessionID, at: 1)

            guard try statement.step() == SQLite.row else {
                return nil
            }

            guard let rawID = statement.text(at: 0) else {
                return nil
            }

            return UUID(uuidString: rawID)
        }
    }

    private func loadTabs(sessionID: String) throws -> [StoredBrowserTab] {
        try withStatement(
            """
            SELECT id, position, title, url
            FROM tabs
            WHERE session_id = ?
            ORDER BY position ASC
            """
        ) { statement in
            try statement.bind(sessionID, at: 1)

            var tabs: [StoredBrowserTab] = []
            while try statement.step() == SQLite.row {
                guard let rawID = statement.text(at: 0),
                      let id = UUID(uuidString: rawID) else {
                    continue
                }

                let rawURL = statement.text(at: 3)
                tabs.append(
                    StoredBrowserTab(
                        id: id,
                        position: Int(statement.int64(at: 1)),
                        title: statement.text(at: 2) ?? "New Tab",
                        url: rawURL.flatMap(URL.init(string:))
                    )
                )
            }

            return tabs
        }
    }

    private func userVersion() throws -> Int {
        try withStatement("PRAGMA user_version") { statement in
            guard try statement.step() == SQLite.row else {
                return 0
            }

            return Int(statement.int64(at: 0))
        }
    }

    private func transaction(_ operation: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")

        do {
            try operation()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sql.withCString { sqlite3_exec(db, $0, nil, nil, &errorMessage) }

        guard result == SQLite.ok else {
            let message: String
            if let errorMessage {
                message = String(cString: errorMessage)
                sqlite3_free(errorMessage)
            } else {
                message = db.map(SQLite.message(for:)) ?? "SQLite command failed."
            }
            throw BrowserDatabaseError.sqliteFailure(message)
        }
    }

    private func withStatement<T>(_ sql: String, _ operation: (SQLiteStatement) throws -> T) throws -> T {
        try operation(SQLiteStatement(db: db, sql: sql))
    }
}
