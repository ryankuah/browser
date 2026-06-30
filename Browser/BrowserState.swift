import AppKit
import Foundation
import Security
import SwiftUI
import WebKit

@MainActor
final class BrowserState: NSObject, ObservableObject, WKUIDelegate, WKDownloadDelegate {
    private static let consoleMessageLimit = 500
    private static let recentlyClosedTabLimit = 20

    @Published private(set) var tabs: [BrowserTab] = []
    @Published private(set) var bookmarks: [BrowserBookmark] = []
    @Published private(set) var historyEntries: [BrowserHistoryEntry] = []
    @Published private(set) var historyVisits: [BrowserHistoryVisit] = []
    @Published private(set) var historyJourneys: [BrowserHistoryJourney] = []
    @Published private(set) var autocompleteSites: [BrowserAutocompleteSite] = []
    @Published private(set) var autocompletePages: [BrowserAutocompletePage] = []
    @Published private(set) var downloads: [BrowserDownload] = []
    @Published private(set) var consoleMessages: [BrowserConsoleMessage] = []
    @Published private(set) var toasts: [BrowserToast] = []
    @Published private(set) var zoomHUD: BrowserZoomHUD?
    @Published var selectedTabID: BrowserTab.ID?
    @Published private(set) var profiles: [BrowserProfile] = []
    @Published private(set) var selectedProfileID: BrowserProfile.ID?
    @Published private(set) var hasLoadedStartupData = false
    @Published private(set) var bezelStyle: BrowserBezelStyle = .liquidGlass
    @Published private(set) var searchEngine: BrowserSearchEngine = .google
    @Published private(set) var userScripts: [BrowserUserScript] = []
    @Published private var mountRequestedTabIDs: Set<BrowserTab.ID> = []
    @Published private var tabStateRevision = 0
    @Published private var mediaPermissionDecisionsByOrigin: [String: [BrowserMediaDeviceKind: Bool]] = [:]
    @Published private(set) var isElementFullscreenActive = false

    private let persistence = BrowserPersistenceStore()
    private var startupLoadTask: Task<Void, Never>?
    private var sessionPersistenceTask: Task<Void, Never>?
    private var mountedTabIDs: Set<BrowserTab.ID> = []
    private var pendingTabLoads: [BrowserTab.ID: URL] = [:]
    private var bookmarkFaviconTasks: [BrowserBookmark.ID: Task<Void, Never>] = [:]
    private var activeDownloads: [BrowserDownload.ID: WKDownload] = [:]
    private var activeDownloadProgressObservations: [BrowserDownload.ID: [NSKeyValueObservation]] = [:]
    private var activeDownloadProgressSnapshots: [BrowserDownload.ID: (receivedBytes: Int64, date: Date)] = [:]
    private var downloadIDsByDownload: [ObjectIdentifier: BrowserDownload.ID] = [:]
    private var toastIDsByDownloadID: [BrowserDownload.ID: BrowserToast.ID] = [:]
    private var mediaPermissionRequests: [BrowserToast.ID: BrowserMediaPermissionRequest] = [:]
    private var toastDismissalTasks: [BrowserToast.ID: Task<Void, Never>] = [:]
    private var zoomHUDDismissalTask: Task<Void, Never>?
    private var recentlyClosedTabs: [RecentlyClosedTab] = []
    private var isApplyingStoredState = false
    private var historyCursorByTabID: [BrowserTab.ID: BrowserHistoryCursor] = [:]
    private var historyURLByTabID: [BrowserTab.ID: String] = [:]
    private var historyRecordTasksByTabID: [BrowserTab.ID: Task<Void, Never>] = [:]
    private var historyCursorSourceByTabID: [BrowserTab.ID: BrowserTab.ID] = [:]
    private weak var cloudSync: BrowserCloudSynchronizing?

    var activeTab: BrowserTab? {
        tabs.first { $0.id == selectedTabID }
    }

    var selectedProfile: BrowserProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    var isOnboardingRequired: Bool {
        hasLoadedStartupData && profiles.isEmpty
    }

    var profileColorHex: String {
        selectedProfile?.colorHex ?? BrowserProfile.defaultColorHex
    }

    var profileNSColor: NSColor {
        NSColor(hexString: profileColorHex) ?? NSColor.systemBlue
    }

    var profileColor: Color {
        Color(nsColor: profileNSColor)
    }

    var profilePrefersDarkForeground: Bool {
        profileNSColor.prefersDarkForeground
    }

    var visibleTabs: [BrowserTab] {
        tabs.filter { bookmarkID(owning: $0.id) == nil }
    }

    var activeMediaPermissionSnapshot: BrowserMediaPermissionSnapshot {
        guard let originKey = activeOriginKey else {
            return BrowserMediaPermissionSnapshot(
                hasActivePage: false,
                isCameraAllowed: false,
                isMicrophoneAllowed: false
            )
        }

        let decisions = mediaPermissionDecisionsByOrigin[originKey] ?? [:]
        return BrowserMediaPermissionSnapshot(
            hasActivePage: true,
            isCameraAllowed: decisions[.camera] == true,
            isMicrophoneAllowed: decisions[.microphone] == true
        )
    }

    var downloadsDirectoryDisplayPath: String {
        let path = Self.downloadsDirectory.path
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path

        if path == homePath {
            return "~"
        }

        if path.hasPrefix(homePath + "/") {
            return "~" + path.dropFirst(homePath.count)
        }

        return path
    }

    func openDownloadsFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([Self.downloadsDirectory])
    }

    func copyDownloadsDirectoryPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.downloadsDirectory.path, forType: .string)
    }

    override init() {
        super.init()
        loadPersistedState()
    }

    deinit {
        startupLoadTask?.cancel()
        sessionPersistenceTask?.cancel()
        bookmarkFaviconTasks.values.forEach { $0.cancel() }
        historyRecordTasksByTabID.values.forEach { $0.cancel() }
        historyCursorSourceByTabID.removeAll()
        toastDismissalTasks.values.forEach { $0.cancel() }
        zoomHUDDismissalTask?.cancel()
    }

    func newTab(url: URL? = nil) {
        _ = createTab(url: url, persist: true)
    }

    func setCloudSync(_ cloudSync: BrowserCloudSynchronizing?) {
        self.cloudSync = cloudSync
        if let cloudSync {
            Task {
                await cloudSync.saveProfiles(profiles, activeProfileID: selectedProfileID)
                await cloudSync.saveSettings([
                    "activeProfileID": selectedProfileID?.uuidString ?? "",
                    "bezelStyle": bezelStyle.rawValue,
                    "searchEngine": searchEngine.rawValue
                ])
                if let selectedProfileID {
                    let snapshot = cloudSessionSnapshot()
                    await cloudSync.saveProfileState(
                        profileID: selectedProfileID,
                        tabs: snapshot.tabs,
                        selectedTabID: snapshot.selectedTabID,
                        bookmarks: bookmarks
                    )
                }
            }
        }
    }

    func openExternalURL(_ url: URL) {
        guard BrowserNavigation.isAllowedNavigationURL(url) else {
            return
        }

        newTab(url: url)
    }

    @discardableResult
    private func createTab(url: URL?, persist: Bool) -> BrowserTab {
        let tab = makeTab(url: url)
        historyCursorByTabID[tab.id] = BrowserHistoryCursor(journeyID: UUID())
        tabs.append(tab)
        selectedTabID = tab.id

        if persist {
            persistSession()
        }

        if let url {
            load(url, in: tab)
        }

        return tab
    }

    func closeTab(id: BrowserTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return
        }

        rememberClosedTab(tabs[index], position: index)

        let wasSelected = selectedTabID == id
        mountRequestedTabIDs.remove(id)
        mountedTabIDs.remove(id)
        pendingTabLoads.removeValue(forKey: id)
        historyCursorByTabID.removeValue(forKey: id)
        historyURLByTabID.removeValue(forKey: id)
        historyRecordTasksByTabID.removeValue(forKey: id)?.cancel()
        historyCursorSourceByTabID.removeValue(forKey: id)
        clearBookmarkTabBinding(for: id)

        tabs.remove(at: index)

        if wasSelected {
            selectedTabID = replacementSelectedTabID(closedIndex: index)
        }

        refreshElementFullscreenState()
        persistSession()
    }

    func closeActiveTab() {
        guard let activeTab else {
            return
        }

        closeTab(id: activeTab.id)
    }

    func reopenLastClosedTab() {
        guard let closedTab = recentlyClosedTabs.popLast() else {
            return
        }

        let tab = makeTab(title: closedTab.title, url: closedTab.url)
        historyCursorByTabID[tab.id] = BrowserHistoryCursor(journeyID: UUID())
        let insertionIndex = min(closedTab.position, tabs.count)
        tabs.insert(tab, at: insertionIndex)
        selectedTabID = tab.id

        if let url = closedTab.url {
            load(url, in: tab)
        }

        persistSession()
    }

    func copyActivePageLink() {
        guard let url = activeTab?.webView.url ?? activeTab?.url else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    func selectTab(id: BrowserTab.ID) {
        guard tabs.contains(where: { $0.id == id }) else {
            return
        }

        selectedTabID = id
        persistSession()
    }

    func selectNavigationItem(atShortcutIndex shortcutIndex: Int) {
        guard (1...9).contains(shortcutIndex) else {
            return
        }

        if bookmarks.indices.contains(shortcutIndex - 1) {
            openBookmark(id: bookmarks[shortcutIndex - 1].id)
            return
        }

        let tabIndex = shortcutIndex - bookmarks.count - 1
        let selectableTabs = visibleTabs
        guard selectableTabs.indices.contains(tabIndex) else {
            return
        }

        selectTab(id: selectableTabs[tabIndex].id)
    }

    func moveVisibleTab(id: BrowserTab.ID, before targetID: BrowserTab.ID?) {
        guard id != targetID,
              bookmarkID(owning: id) == nil,
              let sourceIndex = tabs.firstIndex(where: { $0.id == id }) else {
            return
        }

        let tab = tabs.remove(at: sourceIndex)
        let insertionIndex: Int

        if let targetID,
           bookmarkID(owning: targetID) == nil,
           let targetIndex = tabs.firstIndex(where: { $0.id == targetID }) {
            insertionIndex = targetIndex
        } else if let lastVisibleIndex = tabs.lastIndex(where: { bookmarkID(owning: $0.id) == nil }) {
            insertionIndex = tabs.index(after: lastVisibleIndex)
        } else {
            insertionIndex = tabs.endIndex
        }

        tabs.insert(tab, at: insertionIndex)
        persistSession()
    }

    func navigateAddress(_ address: String) -> Bool {
        guard let url = BrowserNavigation.url(from: address, searchEngine: searchEngine) else {
            return false
        }

        if let activeTab {
            load(url, in: activeTab)
        } else {
            newTab(url: url)
        }

        return true
    }

    func openNewTab(from address: String) -> Bool {
        guard let url = BrowserNavigation.url(from: address, searchEngine: searchEngine) else {
            return false
        }

        newTab(url: url)
        return true
    }

    func openBookmark(id: BrowserBookmark.ID) {
        guard let bookmarkIndex = bookmarks.firstIndex(where: { $0.id == id }) else {
            return
        }

        if let tabID = bookmarks[bookmarkIndex].tabID,
           tabs.contains(where: { $0.id == tabID }) {
            selectedTabID = tabID
            persistSession()
            return
        }

        let bookmark = bookmarks[bookmarkIndex]
        let tab = makeTab(title: bookmark.displayTitle, url: bookmark.url)
        historyCursorByTabID[tab.id] = BrowserHistoryCursor(journeyID: UUID())
        bookmarks[bookmarkIndex].tabID = tab.id
        tabs.insert(tab, at: insertionIndexForBookmark(at: bookmarkIndex))
        selectedTabID = tab.id
        persistSession()
        load(bookmark.url, in: tab)
    }

    func bookmarkTab(id: BrowserTab.ID) {
        guard let tab = tabs.first(where: { $0.id == id }),
              let url = tab.webView.url ?? tab.url,
              BrowserNavigation.isAllowedNavigationURL(url) else {
            return
        }

        clearBookmarkTabBinding(for: id)

        if let bookmarkIndex = bookmarks.firstIndex(where: { BrowserNavigation.isSameBookmarkPage($0.url, url) }) {
            bookmarks[bookmarkIndex].tabID = id
            bookmarks[bookmarkIndex].title = tab.displayTitle
            if bookmarks[bookmarkIndex].favicon == nil {
                bookmarks[bookmarkIndex].favicon = tab.favicon
            }
            persistBookmark(bookmarks[bookmarkIndex], position: bookmarkIndex)
            persistSession()
            return
        }

        let bookmark = BrowserBookmark(
            id: UUID(),
            title: tab.displayTitle,
            url: url,
            favicon: tab.favicon,
            tabID: id
        )

        bookmarks.append(bookmark)
        persistBookmark(bookmark, position: bookmarks.count - 1)
        loadBookmarkFaviconIfNeeded(bookmark)
        persistSession()
    }

    func unpinTab(id: BrowserTab.ID) {
        if let bookmarkID = bookmarkID(owning: id) {
            removeBookmark(id: bookmarkID)
            persistSession()
            return
        }

        guard let tab = tabs.first(where: { $0.id == id }),
              let url = tab.webView.url ?? tab.url,
              let bookmark = bookmark(for: url) else {
            return
        }

        removeBookmark(id: bookmark.id)
        persistSession()
    }

    func unpinBookmark(id: BrowserBookmark.ID) {
        guard bookmarks.contains(where: { $0.id == id }) else {
            return
        }

        removeBookmark(id: id)
        persistSession()
    }

    func isTabBookmarked(id: BrowserTab.ID) -> Bool {
        if bookmarkID(owning: id) != nil {
            return true
        }

        guard let tab = tabs.first(where: { $0.id == id }) else {
            return false
        }

        return isBookmarked(tab.webView.url ?? tab.url)
    }

    func isBookmarked(_ url: URL?) -> Bool {
        guard let url else {
            return false
        }

        return bookmark(for: url) != nil
    }

    func isBookmarkActive(id: BrowserBookmark.ID) -> Bool {
        guard let selectedTabID else {
            return false
        }

        return bookmarks.first(where: { $0.id == id })?.tabID == selectedTabID
    }

    func shouldMountWebView(for tab: BrowserTab) -> Bool {
        tab.url != nil || mountRequestedTabIDs.contains(tab.id) || mountedTabIDs.contains(tab.id)
    }

    func webViewDidMount(for tabID: BrowserTab.ID) {
        mountedTabIDs.insert(tabID)

        guard let url = pendingTabLoads.removeValue(forKey: tabID),
              let tab = tabs.first(where: { $0.id == tabID }) else {
            return
        }

        load(url, in: tab)
    }

    func goBack() {
        activeTab?.goBack()
    }

    func goForward() {
        activeTab?.goForward()
    }

    func reloadOrStop() {
        activeTab?.reloadOrStop()
    }

    func retryActivePageFailure() {
        activeTab?.retryPageFailure()
    }

    func zoomInActiveTab() {
        updateActiveTabZoom { tab in
            tab.zoomIn()
        }
    }

    func zoomOutActiveTab() {
        updateActiveTabZoom { tab in
            tab.zoomOut()
        }
    }

    func resetActiveTabZoom() {
        updateActiveTabZoom { tab in
            tab.resetZoom()
        }
    }

    func findInActivePage(_ query: String, backwards: Bool, completion: @escaping (Bool) -> Void) {
        guard let activeTab else {
            completion(false)
            return
        }

        activeTab.findInPage(query, backwards: backwards, completion: completion)
    }

    func clearActiveFindSelection() {
        activeTab?.clearFindSelection()
    }

    func clearConsoleMessages() {
        consoleMessages = []
    }

    func receiveConsoleMessage(_ body: Any) {
        guard let payload = body as? [String: Any] else {
            appendConsoleMessage(
                level: "log",
                message: String(describing: body),
                url: nil,
                source: "page"
            )
            return
        }

        appendConsoleMessage(
            level: payload["level"] as? String ?? "log",
            message: payload["message"] as? String ?? "",
            url: payload["url"] as? String,
            source: payload["source"] as? String ?? "page"
        )
    }

    func openDownloadedFile(_ download: BrowserDownload) {
        guard download.status == .finished, let destinationURL = download.destinationURL else {
            return
        }

        NSWorkspace.shared.open(destinationURL)
    }

    func showDownloadInFinder(_ download: BrowserDownload) {
        guard let destinationURL = download.destinationURL else {
            return
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
        } else {
            NSWorkspace.shared.open(destinationURL.deletingLastPathComponent())
        }
    }

    func copyDownloadFilePath(_ download: BrowserDownload) {
        guard let destinationURL = download.destinationURL else {
            return
        }

        copyToPasteboard(destinationURL.path)
    }

    func copyDownloadSourceURL(_ download: BrowserDownload) {
        guard let sourceURL = download.sourceURL else {
            return
        }

        copyToPasteboard(sourceURL.absoluteString)
    }

    func cancelDownload(id: BrowserDownload.ID) {
        guard let download = activeDownloads[id] else {
            markDownloadCanceled(id: id)
            return
        }

        download.cancel { [weak self] _ in
            Task { @MainActor in
                self?.markDownloadCanceled(id: id)
                self?.removeActiveDownload(download)
            }
        }
    }

    func retryDownload(id: BrowserDownload.ID) {
        guard let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].canRetry,
              let sourceURL = downloads[index].sourceURL else {
            return
        }

        guard let webView = activeTab?.webView ?? tabs.first?.webView else {
            updateDownload(id: id) { item in
                item.status = .failed
                item.finishedAt = Date()
                item.errorMessage = "No active web view"
            }
            persistDownload(id: id)
            return
        }

        updateDownload(id: id) { item in
            item.destinationURL = nil
            item.receivedBytes = 0
            item.expectedBytes = nil
            item.speedBytesPerSecond = nil
            item.startedAt = Date()
            item.finishedAt = nil
            item.status = .inProgress
            item.errorMessage = nil
        }
        persistDownload(id: id)

        webView.startDownload(using: URLRequest(url: sourceURL)) { [weak self] download in
            Task { @MainActor in
                self?.attach(download, toExistingID: id)
            }
        }
    }

    func openDownloadedFile(id: BrowserDownload.ID) {
        guard let download = downloads.first(where: { $0.id == id }) else {
            return
        }

        openDownloadedFile(download)
        dismissToast(forDownloadID: id)
    }

    func refreshHistoryEntries(limit: Int = 500) {
        Task { [weak self, persistence] in
            async let entries = persistence.loadHistoryEntries(limit: limit)
            async let visits = persistence.loadHistoryVisits(limit: limit)
            async let treeNodes = persistence.loadHistoryTreeNodes(limit: limit)
            await self?.applyHistoryEntries(entries)
            await self?.applyHistoryVisits(visits)
            await self?.applyHistoryTreeNodes(treeNodes)
        }
    }

    func refreshAutocompleteData(siteLimit: Int = 500, pageLimit: Int = 1000) {
        Task { [weak self, persistence] in
            async let sites = persistence.loadAutocompleteSites(limit: siteLimit)
            async let pages = persistence.loadAutocompletePages(limit: pageLimit)
            let loadedSites = await sites
            let loadedPages = await pages
            self?.applyAutocompleteSites(loadedSites)
            self?.applyAutocompletePages(loadedPages)
        }
    }

    func openHistoryEntry(_ entry: BrowserHistoryEntry, inNewTab: Bool) {
        openHistoryURL(entry.url, inNewTab: inNewTab)
    }

    func openHistoryURL(_ url: URL, inNewTab: Bool) {
        if inNewTab {
            newTab(url: url)
        } else if let activeTab {
            load(url, in: activeTab)
        } else {
            newTab(url: url)
        }
    }

    func copyHistoryEntryURL(_ entry: BrowserHistoryEntry) {
        copyHistoryURL(entry.url)
    }

    func copyHistoryURL(_ url: URL) {
        copyToPasteboard(url.absoluteString)
    }

    func allowMediaPermissionToast(id: BrowserToast.ID) {
        resolveMediaPermissionToast(id: id, decision: .grant)
    }

    func denyMediaPermissionToast(id: BrowserToast.ID) {
        resolveMediaPermissionToast(id: id, decision: .deny)
    }

    func setBezelStyle(_ style: BrowserBezelStyle) {
        guard bezelStyle != style else {
            return
        }

        bezelStyle = style
        Task { [persistence] in
            await persistence.saveSetting(key: "bezelStyle", value: style.rawValue)
        }
        Task { [cloudSync] in
            await cloudSync?.saveSettings(["bezelStyle": style.rawValue])
        }
    }

    func setSearchEngine(_ engine: BrowserSearchEngine) {
        guard searchEngine != engine else {
            return
        }

        searchEngine = engine
        Task { [persistence] in
            await persistence.saveSetting(key: "searchEngine", value: engine.rawValue)
        }
        Task { [cloudSync] in
            await cloudSync?.saveSettings(["searchEngine": engine.rawValue])
        }
    }

    @discardableResult
    func createUserScript(
        name: String,
        matchPatterns: String,
        source: String,
        isEnabled: Bool,
        injectionTime: BrowserUserScriptInjectionTime,
        forMainFrameOnly: Bool
    ) -> BrowserUserScript.ID? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPatterns = Self.normalizedUserScriptMatchPatterns(matchPatterns)
        guard !trimmedName.isEmpty,
              !trimmedSource.isEmpty,
              !normalizedPatterns.isEmpty else {
            return nil
        }

        let script = BrowserUserScript(
            id: UUID(),
            name: trimmedName,
            matchPatterns: normalizedPatterns,
            source: source,
            isEnabled: isEnabled,
            injectionTime: injectionTime,
            forMainFrameOnly: forMainFrameOnly,
            position: userScripts.count
        )
        userScripts.append(script)
        persistUserScript(script)
        applyUserScriptsToOpenTabs(reloadPages: true)
        return script.id
    }

    func updateUserScript(
        id: BrowserUserScript.ID,
        name: String,
        matchPatterns: String,
        source: String,
        isEnabled: Bool,
        injectionTime: BrowserUserScriptInjectionTime,
        forMainFrameOnly: Bool
    ) {
        guard let index = userScripts.firstIndex(where: { $0.id == id }) else {
            return
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPatterns = Self.normalizedUserScriptMatchPatterns(matchPatterns)
        guard !trimmedName.isEmpty,
              !trimmedSource.isEmpty,
              !normalizedPatterns.isEmpty else {
            return
        }

        userScripts[index].name = trimmedName
        userScripts[index].matchPatterns = normalizedPatterns
        userScripts[index].source = source
        userScripts[index].isEnabled = isEnabled
        userScripts[index].injectionTime = injectionTime
        userScripts[index].forMainFrameOnly = forMainFrameOnly
        let script = userScripts[index]

        persistUserScript(script)
        applyUserScriptsToOpenTabs(reloadPages: true)
    }

    func setUserScriptEnabled(id: BrowserUserScript.ID, isEnabled: Bool) {
        guard let index = userScripts.firstIndex(where: { $0.id == id }),
              userScripts[index].isEnabled != isEnabled else {
            return
        }

        userScripts[index].isEnabled = isEnabled
        let script = userScripts[index]
        persistUserScript(script)
        applyUserScriptsToOpenTabs(reloadPages: true)
    }

    func deleteUserScript(id: BrowserUserScript.ID) {
        guard let index = userScripts.firstIndex(where: { $0.id == id }) else {
            return
        }

        userScripts.remove(at: index)
        for scriptIndex in userScripts.indices {
            userScripts[scriptIndex].position = scriptIndex
        }

        let remainingScripts = userScripts
        Task { [persistence] in
            await persistence.deleteUserScriptAndReindex(
                id: id,
                remainingScripts: remainingScripts.map(Self.storedUserScript(from:))
            )
        }
        applyUserScriptsToOpenTabs(reloadPages: true)
    }

    func createProfile(name: String, colorHex: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return
        }

        let profile = BrowserProfile(
            id: UUID(),
            name: trimmedName,
            colorHex: Self.normalizedProfileColorHex(colorHex),
            position: profiles.count
        )

        profiles.append(profile)
        Task { [persistence] in
            await persistence.saveProfile(StoredBrowserProfile(
                id: profile.id,
                name: profile.name,
                colorHex: profile.colorHex,
                position: profile.position
            ))
        }
        Task { [cloudSync, profiles] in
            await cloudSync?.saveProfiles(profiles, activeProfileID: profile.id)
        }

        switchProfile(id: profile.id)
    }

    func updateProfile(id: BrowserProfile.ID, name: String, colorHex: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            return
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return
        }

        profiles[index].name = trimmedName
        profiles[index].colorHex = Self.normalizedProfileColorHex(colorHex)
        let profile = profiles[index]

        Task { [persistence] in
            await persistence.saveProfile(StoredBrowserProfile(
                id: profile.id,
                name: profile.name,
                colorHex: profile.colorHex,
                position: profile.position
            ))
        }
        Task { [cloudSync, profiles, selectedProfileID] in
            await cloudSync?.saveProfiles(profiles, activeProfileID: selectedProfileID)
        }
    }

    func deleteProfile(id: BrowserProfile.ID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            return
        }

        let wasSelectedProfile = selectedProfileID == id
        if wasSelectedProfile {
            persistSessionImmediately()
            sessionPersistenceTask?.cancel()
        }

        profiles.remove(at: index)
        for profileIndex in profiles.indices {
            profiles[profileIndex].position = profileIndex
        }

        let nextSelectedProfileID = Self.selectedProfileID(from: profiles, storedID: selectedProfileID == id ? nil : selectedProfileID)
        let remainingProfiles = profiles

        if wasSelectedProfile {
            selectedProfileID = nextSelectedProfileID
            isApplyingStoredState = true
            resetProfileScopedState()
            isApplyingStoredState = false
        }

        Task { [weak self, persistence] in
            await persistence.deleteProfileAndReindex(
                id: id,
                activeProfileID: nextSelectedProfileID,
                remainingProfiles: remainingProfiles.map {
                    StoredBrowserProfile(
                        id: $0.id,
                        name: $0.name,
                        colorHex: $0.colorHex,
                        position: $0.position
                    )
                }
            )

            guard wasSelectedProfile, let nextSelectedProfileID else {
                return
            }

            let profileState = await persistence.loadProfileState(profileID: nextSelectedProfileID)
            await MainActor.run {
                guard self?.selectedProfileID == nextSelectedProfileID else {
                    return
                }

                self?.applyProfileState(bookmarks: profileState.bookmarks, session: profileState.session)
            }
        }
        Task { [cloudSync, remainingProfiles] in
            await cloudSync?.saveProfiles(remainingProfiles, activeProfileID: nextSelectedProfileID)
        }
    }

    func switchProfile(id: BrowserProfile.ID) {
        guard profiles.contains(where: { $0.id == id }),
              selectedProfileID != id else {
            return
        }

        persistSessionImmediately()
        sessionPersistenceTask?.cancel()
        selectedProfileID = id
        Task { [persistence] in
            await persistence.setActiveProfileID(id)
        }
        Task { [cloudSync] in
            await cloudSync?.saveSettings(["activeProfileID": id.uuidString])
        }

        isApplyingStoredState = true
        resetProfileScopedState()
        isApplyingStoredState = false

        Task { [weak self, persistence] in
            let profileState = await persistence.loadProfileState(profileID: id)
            await MainActor.run {
                guard self?.selectedProfileID == id else {
                    return
                }

                self?.applyProfileState(bookmarks: profileState.bookmarks, session: profileState.session)
            }
        }
    }

    func toggleActivePageMediaPermission(_ kind: BrowserMediaDeviceKind) {
        guard let originKey = activeOriginKey else {
            return
        }

        var decisions = mediaPermissionDecisionsByOrigin[originKey] ?? [:]
        decisions[kind] = !(decisions[kind] == true)
        mediaPermissionDecisionsByOrigin[originKey] = decisions
        persistMediaPermissionDecision(originKey: originKey, kind: kind, isAllowed: decisions[kind] == true)
    }

    func dismissToast(id: BrowserToast.ID) {
        if mediaPermissionRequests[id] != nil {
            resolveMediaPermissionToast(id: id, decision: .deny)
            return
        }

        removeToast(id: id)
    }

    func showDebugDownloadToast() {
        let id = UUID()
        let download = BrowserDownload(
            id: id,
            sourceURL: URL(string: "https://example.com/debug-download.zip"),
            destinationURL: nil,
            suggestedFilename: "debug-download.zip",
            receivedBytes: 420_000,
            expectedBytes: 1_000_000,
            startedAt: Date(),
            finishedAt: nil,
            status: .inProgress,
            errorMessage: nil
        )

        downloads.insert(download, at: 0)
        showDownloadToast(for: download)
    }

    func showDebugMicrophonePermissionToast() {
        showDebugMediaPermissionToast(
            title: "example.com Wants to Use Microphone",
            message: "Allow access to microphone for this request?",
            iconSystemName: "mic.fill"
        )
    }

    func showDebugVideoPermissionToast() {
        showDebugMediaPermissionToast(
            title: "example.com Wants to Use Camera",
            message: "Allow access to camera for this request?",
            iconSystemName: "video.fill"
        )
    }

    func showDebugJavaScriptAlert() {
        let alert = NSAlert()
        alert.messageText = "example.com"
        alert.informativeText = "This is a debug JavaScript alert."
        alert.addButton(withTitle: "OK")

        runAlert(alert, attachedTo: activeTab?.webView.window) { _ in }
    }

    func showDebugJavaScriptConfirm() {
        let alert = NSAlert()
        alert.messageText = "example.com"
        alert.informativeText = "This is a debug JavaScript confirm dialog."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        runAlert(alert, attachedTo: activeTab?.webView.window) { _ in }
    }

    func showDebugJavaScriptPrompt() {
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        textField.stringValue = "Default text"

        let alert = NSAlert()
        alert.messageText = "example.com"
        alert.informativeText = "This is a debug JavaScript prompt."
        alert.accessoryView = textField
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        runAlert(alert, attachedTo: activeTab?.webView.window) { _ in }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        configuration.userContentController.removeScriptMessageHandler(forName: "browserConsole")

        let newWebView = BrowserWebView(frame: .zero, configuration: configuration)
        newWebView.underPageBackgroundColor = .clear

        let newTab = makeTab(webView: newWebView)
        if let sourceTab = tab(for: webView) {
            historyCursorSourceByTabID[newTab.id] = sourceTab.id
        } else {
            historyCursorByTabID[newTab.id] = BrowserHistoryCursor(journeyID: UUID())
        }
        tabs.append(newTab)
        selectedTabID = newTab.id
        requestMount(for: newTab.id)
        persistSession()

        return newWebView
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else {
            return
        }

        closeTab(id: tab.id)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = dialogTitle(for: frame)
        alert.informativeText = message
        alert.addButton(withTitle: "OK")

        runAlert(alert, attachedTo: webView.window) { _ in
            completionHandler()
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = dialogTitle(for: frame)
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        runAlert(alert, attachedTo: webView.window) { response in
            completionHandler(response == .alertFirstButtonReturn)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        textField.stringValue = defaultText ?? ""

        let alert = NSAlert()
        alert.messageText = dialogTitle(for: frame)
        alert.informativeText = prompt
        alert.accessoryView = textField
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        runAlert(alert, attachedTo: webView.window) { response in
            completionHandler(response == .alertFirstButtonReturn ? textField.stringValue : nil)
        }
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true

        if let window = webView.window {
            panel.beginSheetModal(for: window) { response in
                completionHandler(response == .OK ? panel.urls : nil)
            }
        } else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        let originKey = originKey(for: origin)
        let requestedDeviceKinds = mediaDeviceKinds(for: type)
        let existingDecisions = mediaPermissionDecisionsByOrigin[originKey] ?? [:]

        if requestedDeviceKinds.allSatisfy({ existingDecisions[$0] == true }) {
            decisionHandler(.grant)
            return
        }

        if requestedDeviceKinds.contains(where: { existingDecisions[$0] == false }) {
            decisionHandler(.deny)
            return
        }

        let id = UUID()
        mediaPermissionRequests[id] = BrowserMediaPermissionRequest(
            originKey: originKey,
            deviceKinds: requestedDeviceKinds,
            handler: decisionHandler
        )
        showToast(BrowserToast(
            id: id,
            kind: .mediaPermission,
            title: "\(originDescription(origin)) Wants to Use \(mediaCaptureDescription(type))",
            message: "Allow access to \(mediaCaptureDescription(type).lowercased()) for this request?",
            iconSystemName: mediaCaptureIconSystemName(type),
            status: .pending,
            progressFraction: nil,
            downloadID: nil
        ))
    }

    private func loadPersistedState() {
        startupLoadTask?.cancel()
        startupLoadTask = Task { [weak self, persistence] in
            let startupData = await persistence.loadStartupData()
            self?.applyStartupData(startupData)
        }
    }

    private func applyStartupData(_ startupData: BrowserStartupData) {
        isApplyingStoredState = true

        applySettings(startupData.settings)
        profiles = startupData.profiles.map { storedProfile in
            BrowserProfile(
                id: storedProfile.id,
                name: storedProfile.name,
                colorHex: storedProfile.colorHex,
                position: storedProfile.position
            )
        }
        selectedProfileID = Self.selectedProfileID(from: profiles, storedID: startupData.activeProfileID)
        applyUserScripts(startupData.userScripts)
        applyMediaPermissionDecisions(startupData.mediaPermissionDecisions)
        downloads = startupData.downloads
        applyAutocompleteSites(startupData.autocompleteSites)
        applyAutocompletePages(startupData.autocompletePages)
        if selectedProfileID != nil {
            applyProfileState(bookmarks: startupData.bookmarks, session: startupData.session)
        } else {
            resetProfileScopedState()
        }

        isApplyingStoredState = false
        hasLoadedStartupData = true
    }

    private func applyProfileState(bookmarks storedBookmarks: [StoredBrowserBookmark], session: StoredBrowserSession?) {
        isApplyingStoredState = true
        resetProfileScopedState()
        bookmarks = storedBookmarks.map { storedBookmark in
            BrowserBookmark(
                id: storedBookmark.id,
                title: storedBookmark.title,
                url: storedBookmark.url,
                favicon: nil,
                tabID: nil
            )
        }
        bookmarks.forEach(loadBookmarkFaviconIfNeeded)
        restoreSession(session)
        isApplyingStoredState = false
    }

    private func applySettings(_ settings: [String: String]) {
        if let rawBezelStyle = settings["bezelStyle"],
           let storedBezelStyle = BrowserBezelStyle(rawValue: rawBezelStyle) {
            bezelStyle = storedBezelStyle
        }

        if let rawSearchEngine = settings["searchEngine"],
           let storedSearchEngine = BrowserSearchEngine(rawValue: rawSearchEngine) {
            searchEngine = storedSearchEngine
        }
    }

    private func applyUserScripts(_ storedScripts: [StoredBrowserUserScript]) {
        userScripts = storedScripts.map { storedScript in
            BrowserUserScript(
                id: storedScript.id,
                name: storedScript.name,
                matchPatterns: storedScript.matchPatterns,
                source: storedScript.source,
                isEnabled: storedScript.isEnabled,
                injectionTime: BrowserUserScriptInjectionTime(rawValue: storedScript.injectionTime) ?? .documentEnd,
                forMainFrameOnly: storedScript.forMainFrameOnly,
                position: storedScript.position
            )
        }
    }

    private func applyMediaPermissionDecisions(_ storedDecisions: [StoredMediaPermissionDecision]) {
        var decisionsByOrigin: [String: [BrowserMediaDeviceKind: Bool]] = [:]

        for storedDecision in storedDecisions {
            guard let deviceKind = BrowserMediaDeviceKind(rawValue: storedDecision.deviceKind) else {
                continue
            }

            var decisions = decisionsByOrigin[storedDecision.origin] ?? [:]
            decisions[deviceKind] = storedDecision.isAllowed
            decisionsByOrigin[storedDecision.origin] = decisions
        }

        mediaPermissionDecisionsByOrigin = decisionsByOrigin
    }

    private func applyHistoryEntries(_ storedEntries: [StoredHistoryEntry]) {
        historyEntries = storedEntries.compactMap { storedEntry in
            guard BrowserNavigation.isAllowedNavigationURL(storedEntry.url) else {
                return nil
            }

            return BrowserHistoryEntry(
                title: storedEntry.title,
                url: storedEntry.url,
                lastVisitedAt: storedEntry.lastVisitedAt,
                visitCount: storedEntry.visitCount,
                favicon: storedEntry.faviconData.flatMap(NSImage.init(data:))
            )
        }
    }

    private func applyHistoryVisits(_ storedVisits: [StoredHistoryVisit]) {
        historyVisits = storedVisits.compactMap { storedVisit in
            guard BrowserNavigation.isAllowedNavigationURL(storedVisit.url) else {
                return nil
            }

            return BrowserHistoryVisit(
                id: storedVisit.id,
                title: storedVisit.title,
                url: storedVisit.url,
                visitedAt: storedVisit.visitedAt,
                favicon: storedVisit.faviconData.flatMap(NSImage.init(data:))
            )
        }
    }

    private func applyHistoryTreeNodes(_ storedNodes: [StoredHistoryTreeNode]) {
        let validNodes = storedNodes.filter { BrowserNavigation.isAllowedNavigationURL($0.url) }
        let storedNodeByID = Dictionary(uniqueKeysWithValues: validNodes.map { ($0.id, $0) })
        let nodeByID = Dictionary(uniqueKeysWithValues: validNodes.map { storedNode in
            (
                storedNode.id,
                BrowserHistoryTreeNode(
                    id: storedNode.id,
                    title: storedNode.title,
                    url: storedNode.url,
                    visitedAt: storedNode.visitedAt,
                    favicon: storedNode.faviconData.flatMap(NSImage.init(data:))
                )
            )
        })

        var childrenByParentID: [Int64: [Int64]] = [:]
        var rootIDsByJourneyID: [UUID: [Int64]] = [:]
        var nodesByJourneyID: [UUID: [StoredHistoryTreeNode]] = [:]

        for storedNode in validNodes {
            nodesByJourneyID[storedNode.journeyID, default: []].append(storedNode)
            if let parentID = storedNode.parentID,
               nodeByID[parentID] != nil,
               storedNodeByID[parentID]?.journeyID == storedNode.journeyID {
                childrenByParentID[parentID, default: []].append(storedNode.id)
            } else {
                rootIDsByJourneyID[storedNode.journeyID, default: []].append(storedNode.id)
            }
        }

        func buildNode(id: Int64) -> BrowserHistoryTreeNode? {
            guard var node = nodeByID[id] else {
                return nil
            }

            let childIDs = (childrenByParentID[id] ?? []).sorted {
                (nodeByID[$0]?.visitedAt ?? .distantPast) < (nodeByID[$1]?.visitedAt ?? .distantPast)
            }
            node.children = childIDs.compactMap(buildNode)
            return node
        }

        historyJourneys = nodesByJourneyID.compactMap { journeyID, storedJourneyNodes in
            guard let firstVisitedAt = storedJourneyNodes.map(\.visitedAt).min(),
                  let lastVisitedAt = storedJourneyNodes.map(\.visitedAt).max() else {
                return nil
            }

            let rootIDs = (rootIDsByJourneyID[journeyID] ?? []).sorted {
                (nodeByID[$0]?.visitedAt ?? .distantPast) < (nodeByID[$1]?.visitedAt ?? .distantPast)
            }
            let roots = rootIDs.compactMap(buildNode)
            let title = roots.first?.displayTitle ?? storedJourneyNodes.min { $0.visitedAt < $1.visitedAt }?.title ?? "New Tab"

            return BrowserHistoryJourney(
                id: journeyID,
                title: title,
                startedAt: firstVisitedAt,
                lastVisitedAt: lastVisitedAt,
                roots: roots
            )
        }
        .sorted { $0.lastVisitedAt > $1.lastVisitedAt }
    }

    private func applyAutocompleteSites(_ storedSites: [StoredAutocompleteSite]) {
        autocompleteSites = storedSites.compactMap { storedSite in
            guard BrowserNavigation.isAllowedNavigationURL(storedSite.url) else {
                return nil
            }

            return BrowserAutocompleteSite(
                host: storedSite.host,
                registrableDomain: storedSite.registrableDomain,
                subdomain: storedSite.subdomain,
                title: storedSite.title,
                url: storedSite.url,
                visitCount: storedSite.visitCount,
                lastVisitedAt: storedSite.lastVisitedAt,
                favicon: storedSite.faviconData.flatMap(NSImage.init(data:))
            )
        }
    }

    private func applyAutocompletePages(_ storedPages: [StoredAutocompletePage]) {
        autocompletePages = storedPages.compactMap { storedPage in
            guard BrowserNavigation.isAllowedNavigationURL(storedPage.url) else {
                return nil
            }

            return BrowserAutocompletePage(
                url: storedPage.url,
                title: storedPage.title,
                host: storedPage.host,
                registrableDomain: storedPage.registrableDomain,
                subdomain: storedPage.subdomain,
                visitCount: storedPage.visitCount,
                lastVisitedAt: storedPage.lastVisitedAt,
                favicon: storedPage.faviconData.flatMap(NSImage.init(data:))
            )
        }
    }

    private func restoreSession(_ session: StoredBrowserSession?) {
        guard let session, !session.tabs.isEmpty else {
            tabs = []
            selectedTabID = nil
            _ = createTab(url: nil, persist: false)
            return
        }

        let restoredTabs = session.tabs
            .sorted { $0.position < $1.position }
            .filter { storedTab in
                guard let url = storedTab.url else {
                    return true
                }

                return !BrowserNavigation.isTransientOAuthURL(url)
            }
            .map { storedTab in
                let tab = makeTab(id: storedTab.id, title: storedTab.title, url: storedTab.url)
                historyCursorByTabID[tab.id] = BrowserHistoryCursor(journeyID: UUID())
                if let url = storedTab.url {
                    pendingTabLoads[tab.id] = url
                }
                return tab
            }

        tabs = restoredTabs
        selectedTabID = restoredTabs.contains { $0.id == session.selectedTabID } ? session.selectedTabID : restoredTabs.first?.id
        if tabs.isEmpty {
            _ = createTab(url: nil, persist: false)
        }
    }

    private func resetProfileScopedState() {
        bookmarkFaviconTasks.values.forEach { $0.cancel() }
        bookmarkFaviconTasks.removeAll()
        mountedTabIDs.removeAll()
        pendingTabLoads.removeAll()
        mountRequestedTabIDs = []
        historyCursorByTabID.removeAll()
        historyURLByTabID.removeAll()
        historyRecordTasksByTabID.values.forEach { $0.cancel() }
        historyRecordTasksByTabID.removeAll()
        historyCursorSourceByTabID.removeAll()
        recentlyClosedTabs.removeAll()
        tabs = []
        bookmarks = []
        selectedTabID = nil
        isElementFullscreenActive = false
    }

    private func makeTab(
        id: BrowserTab.ID = UUID(),
        webView: BrowserWebView? = nil,
        title: String = "New Tab",
        url: URL? = nil
    ) -> BrowserTab {
        let resolvedWebView: BrowserWebView
        if let webView {
            resolvedWebView = webView
            BrowserWebView.replaceConfiguredUserScripts(
                on: webView.configuration.userContentController,
                includeConsoleBridge: false,
                userScripts: userScripts
            )
        } else {
            let configuration = WKWebViewConfiguration()
            configureWebViewConfiguration(configuration)
            resolvedWebView = BrowserWebView(frame: .zero, configuration: configuration)
        }

        let tab = BrowserTab(
            id: id,
            webView: resolvedWebView,
            title: title,
            url: url
        )

        tab.attachUIDelegate(self)
        tab.onStateDidChange = { [weak self] tab in
            self?.tabStateDidChange(tab)
        }
        tab.onNavigationDidFinish = { [weak self] tab in
            self?.tabNavigationDidFinish(tab)
        }
        tab.onURLDidChange = { [weak self] tab, url in
            self?.tabURLDidChange(tab, url: url)
        }
        tab.onFaviconDidLoad = { [weak self] tab, favicon in
            self?.tabFaviconDidLoad(tab, favicon: favicon)
        }
        tab.onFullscreenStateDidChange = { [weak self] _ in
            self?.refreshElementFullscreenState()
        }
        tab.onDownloadDidBegin = { [weak self] tab, download, sourceURL in
            self?.begin(download, from: sourceURL ?? tab.url)
        }

        return tab
    }

    private func configureWebViewConfiguration(_ configuration: WKWebViewConfiguration) {
        BrowserWebView.configure(
            configuration,
            consoleMessageHandler: BrowserConsoleScriptMessageHandler(browser: self),
            userScripts: userScripts
        )
    }

    private static func selectedProfileID(from profiles: [BrowserProfile], storedID: UUID?) -> UUID? {
        if let storedID,
           profiles.contains(where: { $0.id == storedID }) {
            return storedID
        }

        return profiles.sorted { $0.position < $1.position }.first?.id
    }

    private static func normalizedProfileColorHex(_ rawValue: String) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixedValue = value.hasPrefix("#") ? value : "#\(value)"
        return NSColor(hexString: prefixedValue)?.hexString ?? BrowserProfile.defaultColorHex
    }

    private static func normalizedUserScriptMatchPatterns(_ rawValue: String) -> String {
        rawValue
            .components(separatedBy: CharacterSet(charactersIn: "\n,"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    nonisolated private static func storedUserScript(from script: BrowserUserScript) -> StoredBrowserUserScript {
        StoredBrowserUserScript(
            id: script.id,
            position: script.position,
            name: script.name,
            matchPatterns: script.matchPatterns,
            source: script.source,
            isEnabled: script.isEnabled,
            injectionTime: script.injectionTime.rawValue,
            forMainFrameOnly: script.forMainFrameOnly
        )
    }

    private func persistUserScript(_ script: BrowserUserScript) {
        Task { [persistence] in
            await persistence.saveUserScript(Self.storedUserScript(from: script))
        }
    }

    private func applyUserScriptsToOpenTabs(reloadPages: Bool) {
        for tab in tabs {
            BrowserWebView.replaceConfiguredUserScripts(
                on: tab.webView.configuration.userContentController,
                includeConsoleBridge: true,
                userScripts: userScripts
            )

            if reloadPages, tab.webView.url != nil {
                tab.webView.reload()
            }
        }
    }

    private func appendConsoleMessage(level: String, message: String, url: String?, source: String) {
        consoleMessages.append(BrowserConsoleMessage(
            date: Date(),
            level: level,
            message: message,
            url: url,
            source: source
        ))

        if consoleMessages.count > Self.consoleMessageLimit {
            consoleMessages.removeFirst(consoleMessages.count - Self.consoleMessageLimit)
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func begin(_ download: WKDownload, from sourceURL: URL?) {
        download.delegate = self

        let id = UUID()
        let displayName = sourceURL?.lastPathComponent.nonEmpty ?? "Download"
        downloads.insert(
            BrowserDownload(
                id: id,
                sourceURL: sourceURL,
                destinationURL: nil,
                suggestedFilename: displayName,
                receivedBytes: 0,
                expectedBytes: nil,
                startedAt: Date(),
                finishedAt: nil,
                status: .inProgress,
                errorMessage: nil
            ),
            at: 0
        )
        attach(download, toExistingID: id)
        showDownloadToast(for: downloads[0])
        persistDownload(id: id)
    }

    private func attach(_ download: WKDownload, toExistingID id: BrowserDownload.ID) {
        download.delegate = self
        activeDownloads[id] = download
        downloadIDsByDownload[ObjectIdentifier(download)] = id
        observeDownloadProgress(download, id: id)
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
        let destinationURL = uniqueDownloadURL(for: suggestedFilename)
        update(download) { item in
            item.suggestedFilename = suggestedFilename
            item.destinationURL = destinationURL
        }
        refreshDownloadToast(download)
        persistDownload(download)
        completionHandler(destinationURL)
    }

    func downloadDidFinish(_ download: WKDownload) {
        update(download) { item in
            item.status = .finished
            item.finishedAt = Date()
        }
        refreshDownloadToast(download)
        persistDownload(download)
        removeActiveDownload(download)
    }

    func download(
        _ download: WKDownload,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.performDefaultHandling, nil)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        update(download) { item in
            item.status = .failed
            item.finishedAt = Date()
            item.errorMessage = Self.isCancellationError(error) ? "Canceled" : error.localizedDescription
        }
        refreshDownloadToast(download)
        persistDownload(download)
        removeActiveDownload(download)
    }

    private func update(_ download: WKDownload, mutate: (inout BrowserDownload) -> Void) {
        guard let id = downloadIDsByDownload[ObjectIdentifier(download)],
              let index = downloads.firstIndex(where: { $0.id == id }) else {
            return
        }

        mutate(&downloads[index])
    }

    private func updateDownload(id: BrowserDownload.ID, mutate: (inout BrowserDownload) -> Void) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else {
            return
        }

        mutate(&downloads[index])
        showDownloadToast(for: downloads[index])
    }

    private func markDownloadCanceled(id: BrowserDownload.ID) {
        updateDownload(id: id) { item in
            guard item.status == .inProgress else {
                return
            }

            item.status = .failed
            item.finishedAt = Date()
            item.speedBytesPerSecond = nil
            item.errorMessage = "Canceled"
        }
        persistDownload(id: id)
    }

    private static func isCancellationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func observeDownloadProgress(_ download: WKDownload, id: BrowserDownload.ID) {
        let progress = download.progress
        activeDownloadProgressSnapshots[id] = (receivedBytes: 0, date: Date())

        let completedObservation = progress.observe(\.completedUnitCount, options: [.initial, .new]) { [weak self] progress, _ in
            Task { @MainActor in
                self?.updateDownloadProgress(id: id, progress: progress)
            }
        }
        let totalObservation = progress.observe(\.totalUnitCount, options: [.initial, .new]) { [weak self] progress, _ in
            Task { @MainActor in
                self?.updateDownloadProgress(id: id, progress: progress)
            }
        }

        activeDownloadProgressObservations[id] = [completedObservation, totalObservation]
    }

    private func updateDownloadProgress(id: BrowserDownload.ID, progress: Progress) {
        guard let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].status == .inProgress else {
            return
        }

        let receivedBytes = max(progress.completedUnitCount, 0)
        let expectedBytes = progress.totalUnitCount > 0 ? progress.totalUnitCount : nil
        let now = Date()
        let previousSnapshot = activeDownloadProgressSnapshots[id]

        var speedBytesPerSecond = downloads[index].speedBytesPerSecond
        if let previousSnapshot {
            let elapsed = now.timeIntervalSince(previousSnapshot.date)
            let byteDelta = receivedBytes - previousSnapshot.receivedBytes
            if elapsed >= 0.35, byteDelta >= 0 {
                speedBytesPerSecond = Int64(Double(byteDelta) / elapsed)
                activeDownloadProgressSnapshots[id] = (receivedBytes: receivedBytes, date: now)
            }
        } else {
            activeDownloadProgressSnapshots[id] = (receivedBytes: receivedBytes, date: now)
        }

        downloads[index].receivedBytes = receivedBytes
        downloads[index].expectedBytes = expectedBytes
        downloads[index].speedBytesPerSecond = speedBytesPerSecond
        showDownloadToast(for: downloads[index])
    }

    private func removeActiveDownload(_ download: WKDownload) {
        let downloadObjectID = ObjectIdentifier(download)
        guard let id = downloadIDsByDownload.removeValue(forKey: downloadObjectID) else {
            return
        }

        activeDownloads.removeValue(forKey: id)
        activeDownloadProgressObservations.removeValue(forKey: id)
        activeDownloadProgressSnapshots.removeValue(forKey: id)
    }

    private func showToast(_ toast: BrowserToast) {
        cancelToastDismissal(id: toast.id)
        toasts.removeAll { $0.id == toast.id }
        toasts.insert(toast, at: 0)
    }

    private func showDebugMediaPermissionToast(title: String, message: String, iconSystemName: String) {
        showToast(BrowserToast(
            id: UUID(),
            kind: .mediaPermission,
            title: title,
            message: message,
            iconSystemName: iconSystemName,
            status: .pending,
            progressFraction: nil,
            downloadID: nil
        ))
    }

    private func removeToast(id: BrowserToast.ID) {
        cancelToastDismissal(id: id)
        mediaPermissionRequests.removeValue(forKey: id)
        if let toast = toasts.first(where: { $0.id == id }), let downloadID = toast.downloadID {
            toastIDsByDownloadID.removeValue(forKey: downloadID)
        }
        toasts.removeAll { $0.id == id }
    }

    private func dismissToast(forDownloadID downloadID: BrowserDownload.ID) {
        guard let toastID = toastIDsByDownloadID[downloadID] else {
            return
        }

        removeToast(id: toastID)
    }

    private func resolveMediaPermissionToast(id: BrowserToast.ID, decision: WKPermissionDecision) {
        guard let request = mediaPermissionRequests.removeValue(forKey: id) else {
            removeToast(id: id)
            return
        }

        setMediaPermissionDecision(
            decision == .grant,
            for: request.deviceKinds,
            originKey: request.originKey
        )
        request.handler(decision)
        removeToast(id: id)
    }

    private func showDownloadToast(for download: BrowserDownload) {
        let toastID = toastIDsByDownloadID[download.id] ?? UUID()
        toastIDsByDownloadID[download.id] = toastID

        showToast(BrowserToast(
            id: toastID,
            kind: .download,
            title: download.displayName,
            message: download.detailText,
            iconSystemName: downloadIconSystemName(for: download.status),
            status: toastStatus(for: download.status),
            progressFraction: download.progressFraction,
            downloadID: download.id
        ))

        if download.status != .inProgress {
            scheduleToastDismissal(id: toastID, after: 5)
        }
    }

    private func refreshDownloadToast(_ download: WKDownload) {
        guard let id = downloadIDsByDownload[ObjectIdentifier(download)],
              let item = downloads.first(where: { $0.id == id }) else {
            return
        }

        showDownloadToast(for: item)
    }

    private func scheduleToastDismissal(id: BrowserToast.ID, after delay: TimeInterval) {
        cancelToastDismissal(id: id)
        toastDismissalTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await MainActor.run {
                self?.removeToast(id: id)
            }
        }
    }

    private func cancelToastDismissal(id: BrowserToast.ID) {
        toastDismissalTasks[id]?.cancel()
        toastDismissalTasks.removeValue(forKey: id)
    }

    private func downloadIconSystemName(for status: BrowserDownloadStatus) -> String {
        switch status {
        case .inProgress:
            return "arrow.down.circle"
        case .finished:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.circle.fill"
        }
    }

    private func toastStatus(for downloadStatus: BrowserDownloadStatus) -> BrowserToastStatus {
        switch downloadStatus {
        case .inProgress:
            return .pending
        case .finished:
            return .success
        case .failed:
            return .failure
        }
    }

    private func persistDownload(_ download: WKDownload) {
        guard let id = downloadIDsByDownload[ObjectIdentifier(download)] else {
            return
        }

        persistDownload(id: id)
    }

    private func persistDownload(id: BrowserDownload.ID) {
        guard let item = downloads.first(where: { $0.id == id }) else {
            return
        }

        Task { [persistence] in
            await persistence.saveDownload(item)
        }
    }

    private func persistMediaPermissionDecision(originKey: String, kind: BrowserMediaDeviceKind, isAllowed: Bool) {
        Task { [persistence] in
            await persistence.saveMediaPermissionDecision(
                origin: originKey,
                deviceKind: kind.rawValue,
                isAllowed: isAllowed
            )
        }
    }

    private func uniqueDownloadURL(for suggestedFilename: String) -> URL {
        let fileManager = FileManager.default
        let downloadsDirectory = Self.downloadsDirectory
        let sanitizedName = sanitizedFilename(suggestedFilename.nonEmpty ?? "Download")
        let baseURL = downloadsDirectory.appendingPathComponent(sanitizedName, isDirectory: false)

        guard fileManager.fileExists(atPath: baseURL.path) else {
            return baseURL
        }

        let name = baseURL.deletingPathExtension().lastPathComponent
        let pathExtension = baseURL.pathExtension

        for index in 2...999 {
            let candidateName = pathExtension.isEmpty ? "\(name) \(index)" : "\(name) \(index).\(pathExtension)"
            let candidateURL = downloadsDirectory.appendingPathComponent(candidateName, isDirectory: false)
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        return downloadsDirectory.appendingPathComponent("\(UUID().uuidString)-\(sanitizedName)", isDirectory: false)
    }

    private static var downloadsDirectory: URL {
        let fileManager = FileManager.default
        return fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    private func sanitizedFilename(_ filename: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:")
            .union(.newlines)
            .union(.controlCharacters)
        let components = filename.components(separatedBy: invalidCharacters)
        return components.joined(separator: "-").nonEmpty ?? "Download"
    }

    private func load(_ url: URL, in tab: BrowserTab) {
        guard BrowserNavigation.isAllowedNavigationURL(url) else {
            return
        }

        guard mountedTabIDs.contains(tab.id) || tab.webView.superview != nil else {
            tab.prepareDeferredLoad(url)
            pendingTabLoads[tab.id] = url
            requestMount(for: tab.id)
            persistSession()
            return
        }

        tab.load(url)
    }

    private func requestMount(for tabID: BrowserTab.ID) {
        var tabIDs = mountRequestedTabIDs
        tabIDs.insert(tabID)
        mountRequestedTabIDs = tabIDs
    }

    private func tabStateDidChange(_: BrowserTab) {
        tabStateRevision += 1
        persistSession()
    }

    private func updateActiveTabZoom(_ update: (BrowserTab) -> Void) {
        guard let activeTab else {
            return
        }

        let previousZoom = activeTab.pageZoom
        update(activeTab)

        guard activeTab.pageZoom != previousZoom else {
            return
        }

        showZoomHUD(for: activeTab)
    }

    private func showZoomHUD(for tab: BrowserTab) {
        let hud = BrowserZoomHUD(percentText: tab.pageZoomPercentText)
        zoomHUDDismissalTask?.cancel()
        zoomHUD = hud

        zoomHUDDismissalTask = Task { @MainActor [weak self, hudID = hud.id] in
            try? await Task.sleep(nanoseconds: 900_000_000)

            guard !Task.isCancelled,
                  self?.zoomHUD?.id == hudID else {
                return
            }

            self?.zoomHUD = nil
        }
    }

    private func tabNavigationDidFinish(_ tab: BrowserTab) {
        persistSession()
        refreshHistoryMetadataIfNeeded()
    }

    private func tabURLDidChange(_ tab: BrowserTab, url: URL) {
        guard !BrowserNavigation.isTransientOAuthURL(url) else {
            return
        }

        persistSession()

        let urlString = url.absoluteString
        if historyURLByTabID[tab.id] == urlString {
            return
        }

        let title = tab.displayTitle
        let tabID = tab.id
        historyURLByTabID[tabID] = urlString
        enqueueHistoryRecord(tabID: tabID, url: url, title: title)
    }

    private func refreshHistoryMetadataIfNeeded() {
        if historyEntries.isEmpty == false || historyVisits.isEmpty == false || historyJourneys.isEmpty == false {
            refreshHistoryEntries()
        }
    }

    private func enqueueHistoryRecord(
        tabID: BrowserTab.ID,
        url: URL,
        title: String
    ) {
        guard !BrowserNavigation.isTransientOAuthURL(url) else {
            return
        }

        let previousTask = historyRecordTasksByTabID[tabID]
        let task = Task { [weak self, persistence] in
            await previousTask?.value
            guard !Task.isCancelled else {
                return
            }

            let sourceTask = await MainActor.run { () -> Task<Void, Never>? in
                guard let self,
                      let sourceTabID = self.historyCursorSourceByTabID[tabID] else {
                    return nil
                }

                return self.historyRecordTasksByTabID[sourceTabID]
            }
            await sourceTask?.value
            guard !Task.isCancelled else {
                return
            }

            let treeRelationship = await MainActor.run {
                self?.adoptPendingHistoryCursorSource(for: tabID)
                return self?.historyTreeRelationship(for: tabID, url: url)
            }

            guard let treeRelationship else {
                await MainActor.run {
                    self?.refreshHistoryMetadataIfNeeded()
                }
                return
            }

            let visitID = await persistence.recordHistoryVisit(
                url: url,
                title: title,
                tabID: tabID,
                journeyID: treeRelationship.journeyID,
                parentVisitID: treeRelationship.parentVisitID
            )
            if let cloudSync = await MainActor.run(body: { self?.cloudSync }) {
                await cloudSync.recordHistoryVisit(BrowserCloudHistoryVisit(
                    clientId: visitID.map { String($0) } ?? UUID().uuidString,
                    url: url,
                    title: title,
                    tabID: tabID,
                    journeyID: treeRelationship.journeyID,
                    parentVisitID: treeRelationship.parentVisitID.map { String($0) },
                    visitedAt: Date(),
                    origin: BrowserNavigation.originKey(for: url)
                ))
            }

            await MainActor.run {
                if let visitID {
                    self?.recordHistoryTreeVisit(visitID, for: tabID, url: url, relationship: treeRelationship)
                }
                self?.refreshAutocompleteData()
                self?.refreshHistoryMetadataIfNeeded()
            }
        }
        historyRecordTasksByTabID[tabID] = task
    }

    private func historyTreeRelationship(
        for tabID: BrowserTab.ID,
        url: URL
    ) -> BrowserPendingHistoryRelationship? {
        var cursor = historyCursorByTabID[tabID] ?? BrowserHistoryCursor(journeyID: UUID())
        defer {
            historyCursorByTabID[tabID] = cursor
        }

        if cursor.moveToExistingVisit(for: url) {
            return nil
        }

        cursor.removeForwardBranch()
        return BrowserPendingHistoryRelationship(
            journeyID: cursor.journeyID,
            parentVisitID: cursor.currentVisitID
        )
    }

    private func adoptPendingHistoryCursorSource(for tabID: BrowserTab.ID) {
        guard let sourceTabID = historyCursorSourceByTabID.removeValue(forKey: tabID) else {
            return
        }

        if let sourceCursor = historyCursorByTabID[sourceTabID] {
            historyCursorByTabID[tabID] = sourceCursor.cursorForChildTab()
        } else {
            historyCursorByTabID[tabID] = BrowserHistoryCursor(journeyID: UUID())
        }
    }

    private func recordHistoryTreeVisit(
        _ visitID: Int64,
        for tabID: BrowserTab.ID,
        url: URL,
        relationship: BrowserPendingHistoryRelationship
    ) {
        var cursor = historyCursorByTabID[tabID] ?? BrowserHistoryCursor(journeyID: relationship.journeyID)
        cursor.journeyID = relationship.journeyID
        cursor.append(visitID, url: url)
        historyCursorByTabID[tabID] = cursor
        historyURLByTabID[tabID] = url.absoluteString
    }

    private func refreshElementFullscreenState() {
        isElementFullscreenActive = tabs.contains { tab in
            tab.webView.fullscreenState == .enteringFullscreen || tab.webView.fullscreenState == .inFullscreen
        }
    }

    private func persistSession() {
        guard !isApplyingStoredState, let selectedProfileID else {
            return
        }

        let snapshot = sessionSnapshot()

        sessionPersistenceTask?.cancel()
        sessionPersistenceTask = Task { [persistence] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else {
                return
            }
            await persistence.saveSession(
                profileID: selectedProfileID,
                tabs: snapshot.tabs,
                selectedTabID: snapshot.selectedTabID
            )
        }
        Task { [cloudSync, bookmarks] in
            await cloudSync?.saveProfileState(
                profileID: selectedProfileID,
                tabs: snapshot.tabs,
                selectedTabID: snapshot.selectedTabID,
                bookmarks: bookmarks
            )
        }
    }

    private func persistSessionImmediately() {
        guard let selectedProfileID else {
            return
        }

        let snapshot = sessionSnapshot()
        Task { [persistence] in
            await persistence.saveSession(
                profileID: selectedProfileID,
                tabs: snapshot.tabs,
                selectedTabID: snapshot.selectedTabID
            )
        }
        Task { [cloudSync, bookmarks] in
            await cloudSync?.saveProfileState(
                profileID: selectedProfileID,
                tabs: snapshot.tabs,
                selectedTabID: snapshot.selectedTabID,
                bookmarks: bookmarks
            )
        }
    }

    func cloudSessionSnapshot() -> (tabs: [BrowserTabSnapshot], selectedTabID: UUID?) {
        sessionSnapshot()
    }

    private func sessionSnapshot() -> (tabs: [BrowserTabSnapshot], selectedTabID: UUID?) {
        let sessionTabs = tabs.filter { tab in
            guard let url = tab.url else {
                return true
            }

            return !BrowserNavigation.isTransientOAuthURL(url)
        }
        let persistedSelectedTabID = sessionTabs.contains { $0.id == selectedTabID } ? selectedTabID : sessionTabs.first?.id
        let snapshots = sessionTabs.enumerated().map { index, tab in
            BrowserTabSnapshot(
                id: tab.id,
                position: index,
                title: tab.displayTitle,
                url: tab.url
            )
        }

        return (snapshots, persistedSelectedTabID)
    }

    private func tabFaviconDidLoad(_ tab: BrowserTab, favicon: NSImage) {
        guard let pageURL = tab.url,
              let origin = BrowserNavigation.originKey(for: pageURL),
              let imageData = favicon.tiffRepresentation else {
            return
        }

        Task { [weak self, persistence] in
            await persistence.saveFavicon(
                origin: origin,
                pageURL: pageURL,
                imageData: imageData
            )
            await MainActor.run {
                self?.refreshAutocompleteData()
                if self?.historyEntries.isEmpty == false || self?.historyVisits.isEmpty == false || self?.historyJourneys.isEmpty == false {
                    self?.refreshHistoryEntries()
                }
            }
        }
    }

    private func persistBookmark(_ bookmark: BrowserBookmark, position: Int) {
        guard let selectedProfileID else {
            return
        }

        let storedBookmark = StoredBrowserBookmark(
            id: bookmark.id,
            position: position,
            title: bookmark.title,
            url: bookmark.url
        )
        Task { [persistence] in
            await persistence.saveBookmark(storedBookmark, profileID: selectedProfileID)
        }
        let snapshot = sessionSnapshot()
        Task { [cloudSync, bookmarks] in
            await cloudSync?.saveProfileState(
                profileID: selectedProfileID,
                tabs: snapshot.tabs,
                selectedTabID: snapshot.selectedTabID,
                bookmarks: bookmarks
            )
        }
    }

    private func removeBookmark(id: BrowserBookmark.ID) {
        guard let selectedProfileID else {
            return
        }

        bookmarkFaviconTasks[id]?.cancel()
        bookmarkFaviconTasks.removeValue(forKey: id)
        bookmarks.removeAll { $0.id == id }

        let remainingBookmarks = bookmarks.enumerated().map { index, bookmark in
            StoredBrowserBookmark(
                id: bookmark.id,
                position: index,
                title: bookmark.title,
                url: bookmark.url
            )
        }
        Task { [persistence] in
            await persistence.deleteBookmarkAndReindex(
                id: id,
                profileID: selectedProfileID,
                remainingBookmarks: remainingBookmarks
            )
        }
        let snapshot = sessionSnapshot()
        Task { [cloudSync, bookmarks] in
            await cloudSync?.saveProfileState(
                profileID: selectedProfileID,
                tabs: snapshot.tabs,
                selectedTabID: snapshot.selectedTabID,
                bookmarks: bookmarks
            )
        }
    }

    private func bookmark(for url: URL) -> BrowserBookmark? {
        bookmarks.first { BrowserNavigation.isSameBookmarkPage($0.url, url) }
    }

    private func bookmarkID(owning tabID: BrowserTab.ID) -> BrowserBookmark.ID? {
        bookmarks.first { $0.tabID == tabID }?.id
    }

    private func clearBookmarkTabBinding(for tabID: BrowserTab.ID) {
        guard let bookmarkIndex = bookmarks.firstIndex(where: { $0.tabID == tabID }) else {
            return
        }

        bookmarks[bookmarkIndex].tabID = nil
    }

    private func insertionIndexForBookmark(at bookmarkIndex: Int) -> Int {
        let earlierBookmarkTabIDs = Set(bookmarks.prefix(bookmarkIndex).compactMap(\.tabID))
        let index = tabs.lastIndex { earlierBookmarkTabIDs.contains($0.id) }
        return index.map { tabs.index(after: $0) } ?? tabs.startIndex
    }

    private func replacementSelectedTabID(closedIndex: Int) -> BrowserTab.ID? {
        guard !tabs.isEmpty else {
            return nil
        }

        return tabs[min(closedIndex, tabs.count - 1)].id
    }

    private func rememberClosedTab(_ tab: BrowserTab, position: Int) {
        recentlyClosedTabs.append(RecentlyClosedTab(
            title: tab.displayTitle,
            url: tab.webView.url ?? tab.url,
            position: position
        ))

        if recentlyClosedTabs.count > Self.recentlyClosedTabLimit {
            recentlyClosedTabs.removeFirst(recentlyClosedTabs.count - Self.recentlyClosedTabLimit)
        }
    }

    private func loadBookmarkFaviconIfNeeded(_ bookmark: BrowserBookmark) {
        guard bookmark.favicon == nil, bookmarkFaviconTasks[bookmark.id] == nil else {
            return
        }

        let bookmarkID = bookmark.id
        let pageURL = bookmark.url
        bookmarkFaviconTasks[bookmarkID] = Task { [weak self] in
            let image = await BrowserTab.fetchFavicon(for: pageURL, webView: nil)

            await MainActor.run {
                guard let self else {
                    return
                }

                self.bookmarkFaviconTasks.removeValue(forKey: bookmarkID)

                guard let image,
                      let index = self.bookmarks.firstIndex(where: { $0.id == bookmarkID }) else {
                    return
                }

                self.bookmarks[index].favicon = image
            }
        }
    }

    private func tab(for webView: WKWebView) -> BrowserTab? {
        tabs.first { $0.webView === webView }
    }

    private var activeOriginKey: String? {
        guard let url = activeTab?.webView.url ?? activeTab?.url else {
            return nil
        }

        return BrowserNavigation.originKey(for: url)
    }

    private func runAlert(_ alert: NSAlert, attachedTo window: NSWindow?, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private func dialogTitle(for frame: WKFrameInfo) -> String {
        frame.request.url?.host() ?? "This webpage"
    }

    private func originDescription(_ origin: WKSecurityOrigin) -> String {
        let port = origin.port == 0 ? "" : ":\(origin.port)"
        return "\(origin.`protocol`)://\(origin.host)\(port)"
    }

    private func originKey(for origin: WKSecurityOrigin) -> String {
        let port = origin.port == 0 ? "" : ":\(origin.port)"
        return "\(origin.`protocol`)://\(origin.host)\(port)"
    }

    private func setMediaPermissionDecision(_ isAllowed: Bool, for kinds: Set<BrowserMediaDeviceKind>, originKey: String) {
        var decisions = mediaPermissionDecisionsByOrigin[originKey] ?? [:]
        for kind in kinds {
            decisions[kind] = isAllowed
            persistMediaPermissionDecision(originKey: originKey, kind: kind, isAllowed: isAllowed)
        }
        mediaPermissionDecisionsByOrigin[originKey] = decisions
    }

    private func mediaDeviceKinds(for type: WKMediaCaptureType) -> Set<BrowserMediaDeviceKind> {
        switch type {
        case .camera:
            return [.camera]
        case .microphone:
            return [.microphone]
        case .cameraAndMicrophone:
            return [.camera, .microphone]
        @unknown default:
            return [.camera, .microphone]
        }
    }

    private func mediaCaptureDescription(_ type: WKMediaCaptureType) -> String {
        switch type {
        case .camera:
            return "Camera"
        case .microphone:
            return "Microphone"
        case .cameraAndMicrophone:
            return "Camera and Microphone"
        @unknown default:
            return "Media Devices"
        }
    }

    private func mediaCaptureIconSystemName(_ type: WKMediaCaptureType) -> String {
        switch type {
        case .camera:
            return "video.fill"
        case .microphone:
            return "mic.fill"
        case .cameraAndMicrophone:
            return "video.badge.waveform.fill"
        @unknown default:
            return "record.circle"
        }
    }

}

private struct RecentlyClosedTab {
    let title: String
    let url: URL?
    let position: Int
}

private struct BrowserPendingHistoryRelationship {
    let journeyID: UUID
    let parentVisitID: Int64?
}

private struct BrowserHistoryCursor {
    private struct Entry {
        let visitID: Int64
        let urlString: String
    }

    var journeyID: UUID
    private var path: [Entry] = []
    private var currentIndex = -1

    init(journeyID: UUID) {
        self.journeyID = journeyID
    }

    var currentVisitID: Int64? {
        guard path.indices.contains(currentIndex) else {
            return nil
        }

        return path[currentIndex].visitID
    }

    mutating func append(_ visitID: Int64, url: URL) {
        removeForwardBranch()
        path.append(Entry(visitID: visitID, urlString: url.absoluteString))
        currentIndex = path.count - 1
    }

    mutating func moveToExistingVisit(for url: URL) -> Bool {
        guard let matchingIndex = path.lastIndex(where: { $0.urlString == url.absoluteString }) else {
            return false
        }

        currentIndex = matchingIndex
        return true
    }

    mutating func removeForwardBranch() {
        guard currentIndex + 1 < path.count else {
            return
        }

        path.removeSubrange((currentIndex + 1)..<path.count)
    }

    func cursorForChildTab() -> BrowserHistoryCursor {
        var cursor = self
        cursor.removeForwardBranch()
        return cursor
    }
}

private struct BrowserMediaPermissionRequest {
    let originKey: String
    let deviceKinds: Set<BrowserMediaDeviceKind>
    let handler: (WKPermissionDecision) -> Void
}
