import Foundation
import SQLite3

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

struct StoredHistorySuggestion: Sendable {
    let title: String
    let url: URL
    let visitedAt: Date
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

    func recordHistoryVisit(url: URL, title: String, tabID: UUID?) throws {
        try withStatement(
            """
            INSERT INTO history_visits (url, title, tab_id, visited_at, origin)
            VALUES (?, ?, ?, ?, ?)
            """
        ) { statement in
            try statement.bind(url.absoluteString, at: 1)
            try statement.bind(title, at: 2)
            try statement.bind(tabID?.uuidString, at: 3)
            try statement.bind(Date().timeIntervalSince1970, at: 4)
            try statement.bind(Self.originKey(for: url), at: 5)
            try statement.stepDone()
        }
    }

    func loadRecentHistorySuggestions(limit: Int) throws -> [StoredHistorySuggestion] {
        try withStatement(
            """
            SELECT history_visits.url, history_visits.title, history_visits.visited_at, favicons.image_data
            FROM history_visits
            INNER JOIN (
                SELECT url, MAX(visited_at) AS latest_visit
                FROM history_visits
                GROUP BY url
            ) latest_visits
                ON latest_visits.url = history_visits.url
                AND latest_visits.latest_visit = history_visits.visited_at
            LEFT JOIN favicons
                ON favicons.origin = history_visits.origin
            GROUP BY history_visits.url
            ORDER BY history_visits.visited_at DESC
            LIMIT ?
            """
        ) { statement in
            try statement.bind(Int64(limit), at: 1)

            var suggestions: [StoredHistorySuggestion] = []
            while try statement.step() == SQLite.row {
                guard let rawURL = statement.text(at: 0),
                      let url = URL(string: rawURL) else {
                    continue
                }

                suggestions.append(
                    StoredHistorySuggestion(
                        title: statement.text(at: 1) ?? url.host() ?? rawURL,
                        url: url,
                        visitedAt: Date(timeIntervalSince1970: statement.double(at: 2)),
                        faviconData: statement.data(at: 3)
                    )
                )
            }

            return suggestions
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

    private static func originKey(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host()?.lowercased() else {
            return nil
        }

        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
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
    }

    private func backfillHistoryVisitOrigins() throws {
        let visits = try withStatement("SELECT id, url FROM history_visits WHERE origin IS NULL") { statement in
            var visits: [(id: Int64, origin: String)] = []
            while try statement.step() == SQLite.row {
                guard let rawURL = statement.text(at: 1),
                      let url = URL(string: rawURL),
                      let origin = Self.originKey(for: url) else {
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

private final class SQLiteStatement {
    private let db: OpaquePointer?
    private var statement: OpaquePointer?

    init(db: OpaquePointer?, sql: String) throws {
        self.db = db

        let result = sql.withCString { sqlPointer in
            sqlite3_prepare_v2(db, sqlPointer, -1, &statement, nil)
        }

        guard result == SQLite.ok else {
            throw BrowserDatabaseError.sqliteFailure(db.map(SQLite.message(for:)) ?? "Could not prepare SQLite statement.")
        }
    }

    deinit {
        _ = sqlite3_finalize(statement)
    }

    func bind(_ value: String?, at index: Int32) throws {
        if let value {
            let result = value.withCString { pointer in
                sqlite3_bind_text(statement, index, pointer, -1, SQLite.transient)
            }
            try check(result)
        } else {
            try check(sqlite3_bind_null(statement, index))
        }
    }

    func bind(_ value: Int64, at index: Int32) throws {
        try check(sqlite3_bind_int64(statement, index, value))
    }

    func bind(_ value: Int64?, at index: Int32) throws {
        if let value {
            try bind(value, at: index)
        } else {
            try check(sqlite3_bind_null(statement, index))
        }
    }

    func bind(_ value: Double, at index: Int32) throws {
        try check(sqlite3_bind_double(statement, index, value))
    }

    func bind(_ value: Double?, at index: Int32) throws {
        if let value {
            try bind(value, at: index)
        } else {
            try check(sqlite3_bind_null(statement, index))
        }
    }

    func bind(_ value: Data?, at index: Int32) throws {
        if let value {
            let result = value.withUnsafeBytes { buffer in
                sqlite3_bind_blob(
                    statement,
                    index,
                    buffer.baseAddress,
                    Int32(value.count),
                    SQLite.transient
                )
            }
            try check(result)
        } else {
            try check(sqlite3_bind_null(statement, index))
        }
    }

    func step() throws -> Int32 {
        let result = sqlite3_step(statement)
        guard result == SQLite.row || result == SQLite.done else {
            throw BrowserDatabaseError.sqliteFailure(SQLite.message(for: db))
        }

        return result
    }

    func stepDone() throws {
        let result = try step()
        guard result == SQLite.done else {
            throw BrowserDatabaseError.sqliteFailure("SQLite statement returned rows where none were expected.")
        }
    }

    func text(at index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLite.null,
              let text = sqlite3_column_text(statement, index) else {
            return nil
        }

        return String(cString: UnsafeRawPointer(text).assumingMemoryBound(to: CChar.self))
    }

    func data(at index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLite.null,
              let bytes = sqlite3_column_blob(statement, index) else {
            return nil
        }

        let byteCount = Int(sqlite3_column_bytes(statement, index))
        guard byteCount > 0 else {
            return nil
        }

        return Data(bytes: bytes, count: byteCount)
    }

    func int64(at index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    func optionalInt64(at index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLite.null else {
            return nil
        }

        return sqlite3_column_int64(statement, index)
    }

    func double(at index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    func optionalDouble(at index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLite.null else {
            return nil
        }

        return sqlite3_column_double(statement, index)
    }

    private func check(_ result: Int32) throws {
        guard result == SQLite.ok else {
            throw BrowserDatabaseError.sqliteFailure(SQLite.message(for: db))
        }
    }
}

private enum SQLite {
    static let ok = SQLITE_OK
    static let row = SQLITE_ROW
    static let done = SQLITE_DONE
    static let null = SQLITE_NULL

    static let openReadWrite = SQLITE_OPEN_READWRITE
    static let openCreate = SQLITE_OPEN_CREATE
    static let openFullMutex = SQLITE_OPEN_FULLMUTEX

    static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    static func message(for db: OpaquePointer?) -> String {
        guard let message = sqlite3_errmsg(db) else {
            return "Unknown SQLite error."
        }

        return String(cString: message)
    }
}
