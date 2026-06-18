import AppKit
import AuthenticationServices
import Foundation
import Security
import WebKit

@MainActor
final class BrowserState: NSObject, ObservableObject, WKUIDelegate, WKDownloadDelegate {
    private static let consoleMessageLimit = 500
    private static let passkeyEntitlement = "com.apple.developer.web-browser.public-key-credential"

    @Published private(set) var tabs: [BrowserTab] = []
    @Published private(set) var bookmarks: [BrowserBookmark] = []
    @Published private(set) var historySuggestions: [BrowserHistorySuggestion] = []
    @Published private(set) var downloads: [BrowserDownload] = []
    @Published private(set) var consoleMessages: [BrowserConsoleMessage] = []
    @Published private(set) var toasts: [BrowserToast] = []
    @Published var selectedTabID: BrowserTab.ID?
    @Published private(set) var bezelStyle: BrowserBezelStyle = .liquidGlass
    @Published private(set) var searchEngine: BrowserSearchEngine = .google
    @Published private var mountRequestedTabIDs: Set<BrowserTab.ID> = []
    @Published private var mediaPermissionDecisionsByOrigin: [String: [BrowserMediaDeviceKind: Bool]] = [:]
    @Published private(set) var isElementFullscreenActive = false

    private let persistence = BrowserPersistenceStore()
    private var startupLoadTask: Task<Void, Never>?
    private var sessionPersistenceTask: Task<Void, Never>?
    private var mountedTabIDs: Set<BrowserTab.ID> = []
    private var pendingTabLoads: [BrowserTab.ID: URL] = [:]
    private var bookmarkFaviconTasks: [BrowserBookmark.ID: Task<Void, Never>] = [:]
    private var downloadIDsByDownload: [ObjectIdentifier: BrowserDownload.ID] = [:]
    private var toastIDsByDownloadID: [BrowserDownload.ID: BrowserToast.ID] = [:]
    private var mediaPermissionRequests: [BrowserToast.ID: BrowserMediaPermissionRequest] = [:]
    private var toastDismissalTasks: [BrowserToast.ID: Task<Void, Never>] = [:]
    private let passkeyCredentialManager = ASAuthorizationWebBrowserPublicKeyCredentialManager()
    private var isApplyingStoredState = false

    var activeTab: BrowserTab? {
        tabs.first { $0.id == selectedTabID }
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

    override init() {
        super.init()
        requestPasskeyAccessIfNeeded()
        loadPersistedState()
    }

    deinit {
        startupLoadTask?.cancel()
        sessionPersistenceTask?.cancel()
        bookmarkFaviconTasks.values.forEach { $0.cancel() }
        toastDismissalTasks.values.forEach { $0.cancel() }
    }

    func newTab(url: URL? = nil) {
        _ = createTab(url: url, persist: true)
    }

    @discardableResult
    private func createTab(url: URL?, persist: Bool) -> BrowserTab {
        let tab = makeTab(url: url)
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

        let wasSelected = selectedTabID == id
        mountRequestedTabIDs.remove(id)
        mountedTabIDs.remove(id)
        pendingTabLoads.removeValue(forKey: id)
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

    func loadAddress(_ address: String) {
        guard let url = BrowserNavigation.url(from: address, searchEngine: searchEngine) else {
            return
        }

        if let activeTab {
            load(url, in: activeTab)
        } else {
            newTab(url: url)
        }
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
        bookmarks[bookmarkIndex].tabID = tab.id
        tabs.insert(tab, at: insertionIndexForBookmark(at: bookmarkIndex))
        selectedTabID = tab.id
        persistSession()
        load(bookmark.url, in: tab)
    }

    func toggleBookmarkForActivePage() {
        guard let url = activeTab?.webView.url ?? activeTab?.url,
              BrowserNavigation.isAllowedNavigationURL(url) else {
            return
        }

        if let bookmark = bookmark(for: url) {
            removeBookmark(id: bookmark.id)
            return
        }

        let bookmark = BrowserBookmark(
            id: UUID(),
            title: activeTab?.displayTitle ?? BrowserNavigation.defaultTitle(for: url),
            url: url,
            favicon: activeTab?.favicon,
            tabID: activeTab?.id
        )

        if let activeTab {
            clearBookmarkTabBinding(for: activeTab.id)
        }
        bookmarks.append(bookmark)
        persistBookmark(bookmark, position: bookmarks.count - 1)
        loadBookmarkFaviconIfNeeded(bookmark)
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

    func openDownloadedFile(id: BrowserDownload.ID) {
        guard let download = downloads.first(where: { $0.id == id }) else {
            return
        }

        openDownloadedFile(download)
        dismissToast(forDownloadID: id)
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
    }

    func setSearchEngine(_ engine: BrowserSearchEngine) {
        guard searchEngine != engine else {
            return
        }

        searchEngine = engine
        Task { [persistence] in
            await persistence.saveSetting(key: "searchEngine", value: engine.rawValue)
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

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        configureWebViewConfiguration(configuration)

        let webView = BrowserWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .clear

        let tab = makeTab(webView: webView)
        tabs.append(tab)
        selectedTabID = tab.id
        requestMount(for: tab.id)
        persistSession()

        return webView
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
        applyMediaPermissionDecisions(startupData.mediaPermissionDecisions)
        downloads = startupData.downloads
        bookmarks = startupData.bookmarks.map { storedBookmark in
            BrowserBookmark(
                id: storedBookmark.id,
                title: storedBookmark.title,
                url: storedBookmark.url,
                favicon: nil,
                tabID: nil
            )
        }
        bookmarks.forEach(loadBookmarkFaviconIfNeeded)
        applyHistorySuggestions(startupData.historySuggestions)
        restoreSession(startupData.session)

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

    private func applyHistorySuggestions(_ storedSuggestions: [StoredHistorySuggestion]) {
        historySuggestions = storedSuggestions.compactMap { storedSuggestion in
            guard BrowserNavigation.isAllowedNavigationURL(storedSuggestion.url) else {
                return nil
            }

            return BrowserHistorySuggestion(
                title: storedSuggestion.title,
                url: storedSuggestion.url,
                visitedAt: storedSuggestion.visitedAt,
                favicon: storedSuggestion.faviconData.flatMap(NSImage.init(data:))
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
            .map { storedTab in
                let tab = makeTab(id: storedTab.id, title: storedTab.title, url: storedTab.url)
                if let url = storedTab.url {
                    pendingTabLoads[tab.id] = url
                }
                return tab
            }

        tabs = restoredTabs
        selectedTabID = restoredTabs.contains { $0.id == session.selectedTabID } ? session.selectedTabID : restoredTabs.first?.id
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
        } else {
            let configuration = BrowserWebView.makeConfiguration()
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
        BrowserWebView.configure(configuration, consoleMessageHandler: BrowserConsoleScriptMessageHandler(browser: self))
    }

    private func requestPasskeyAccessIfNeeded() {
        guard Self.hasBooleanEntitlement(Self.passkeyEntitlement) else {
            NSLog("Browser passkey access is unavailable because \(Self.passkeyEntitlement) is not present")
            return
        }

        let state = passkeyCredentialManager.authorizationStateForPlatformCredentials

        switch state {
        case .authorized, .denied:
            Self.logPasskeyAuthorizationState(state)
        case .notDetermined:
            passkeyCredentialManager.requestAuthorizationForPublicKeyCredentials { state in
                BrowserState.logPasskeyAuthorizationState(state)
            }
        @unknown default:
            BrowserState.logPasskeyAuthorizationState(state)
        }
    }

    nonisolated private static func logPasskeyAuthorizationState(_ state: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState) {
        let label: String

        switch state {
        case .authorized:
            label = "authorized"
        case .denied:
            label = "denied"
        case .notDetermined:
            label = "not determined"
        @unknown default:
            label = "unknown"
        }

        NSLog("Browser passkey access is \(label)")
    }

    nonisolated private static func hasBooleanEntitlement(_ key: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil) else {
            return false
        }

        return (value as? Bool) == true
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

    private func begin(_ download: WKDownload, from sourceURL: URL?) {
        download.delegate = self

        let id = UUID()
        let displayName = sourceURL?.lastPathComponent.nonEmpty ?? "Download"
        downloadIDsByDownload[ObjectIdentifier(download)] = id
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
        showDownloadToast(for: downloads[0])
        persistDownload(id: id)
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
        downloadIDsByDownload.removeValue(forKey: ObjectIdentifier(download))
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
            item.errorMessage = error.localizedDescription
        }
        refreshDownloadToast(download)
        persistDownload(download)
        downloadIDsByDownload.removeValue(forKey: ObjectIdentifier(download))
    }

    private func update(_ download: WKDownload, mutate: (inout BrowserDownload) -> Void) {
        guard let id = downloadIDsByDownload[ObjectIdentifier(download)],
              let index = downloads.firstIndex(where: { $0.id == id }) else {
            return
        }

        mutate(&downloads[index])
    }

    private func showToast(_ toast: BrowserToast) {
        cancelToastDismissal(id: toast.id)
        toasts.removeAll { $0.id == toast.id }
        toasts.insert(toast, at: 0)
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

    private func tabStateDidChange(_ tab: BrowserTab) {
        persistSession()
    }

    private func tabNavigationDidFinish(_ tab: BrowserTab) {
        persistSession()

        guard let url = tab.url else {
            return
        }

        let title = tab.displayTitle
        let tabID = tab.id
        Task { [weak self, persistence] in
            let suggestions = await persistence.recordHistoryVisitAndLoadSuggestions(
                url: url,
                title: title,
                tabID: tabID,
                limit: 80
            )
            self?.applyHistorySuggestions(suggestions)
        }
    }

    private func refreshElementFullscreenState() {
        isElementFullscreenActive = tabs.contains { tab in
            tab.webView.fullscreenState == .enteringFullscreen || tab.webView.fullscreenState == .inFullscreen
        }
    }

    private func persistSession() {
        guard !isApplyingStoredState else {
            return
        }

        let sessionTabs = tabs
        let persistedSelectedTabID = sessionTabs.contains { $0.id == selectedTabID } ? selectedTabID : sessionTabs.first?.id
        let snapshots = sessionTabs.enumerated().map { index, tab in
            BrowserTabSnapshot(
                id: tab.id,
                position: index,
                title: tab.displayTitle,
                url: tab.url
            )
        }

        sessionPersistenceTask?.cancel()
        sessionPersistenceTask = Task { [persistence] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else {
                return
            }
            await persistence.saveDefaultSession(tabs: snapshots, selectedTabID: persistedSelectedTabID)
        }
    }

    private func tabFaviconDidLoad(_ tab: BrowserTab, favicon: NSImage) {
        guard let pageURL = tab.url,
              let origin = BrowserNavigation.originKey(for: pageURL),
              let imageData = favicon.tiffRepresentation else {
            return
        }

        Task { [weak self, persistence] in
            let suggestions = await persistence.saveFaviconAndLoadSuggestions(
                origin: origin,
                pageURL: pageURL,
                imageData: imageData,
                limit: 80
            )
            self?.applyHistorySuggestions(suggestions)
        }
    }

    private func persistBookmark(_ bookmark: BrowserBookmark, position: Int) {
        let storedBookmark = StoredBrowserBookmark(
            id: bookmark.id,
            position: position,
            title: bookmark.title,
            url: bookmark.url
        )
        Task { [persistence] in
            await persistence.saveBookmark(storedBookmark)
        }
    }

    private func removeBookmark(id: BrowserBookmark.ID) {
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
            await persistence.deleteBookmarkAndReindex(id: id, remainingBookmarks: remainingBookmarks)
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

private struct BrowserMediaPermissionRequest {
    let originKey: String
    let deviceKinds: Set<BrowserMediaDeviceKind>
    let handler: (WKPermissionDecision) -> Void
}
