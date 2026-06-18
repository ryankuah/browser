import AppKit
import Foundation
import WebKit

enum BrowserDownloadStatus: Equatable {
    case inProgress
    case finished
    case failed

    init(storageValue: String) {
        switch storageValue {
        case "finished":
            self = .finished
        case "failed":
            self = .failed
        default:
            self = .inProgress
        }
    }

    var storageValue: String {
        switch self {
        case .inProgress:
            return "inProgress"
        case .finished:
            return "finished"
        case .failed:
            return "failed"
        }
    }

    var label: String {
        switch self {
        case .inProgress:
            return "Downloading"
        case .finished:
            return "Finished"
        case .failed:
            return "Failed"
        }
    }
}

struct BrowserDownload: Identifiable, Equatable {
    let id: UUID
    let sourceURL: URL?
    var destinationURL: URL?
    var suggestedFilename: String
    var receivedBytes: Int64
    var expectedBytes: Int64?
    var startedAt: Date
    var finishedAt: Date?
    var status: BrowserDownloadStatus
    var errorMessage: String?

    var displayName: String {
        destinationURL?.lastPathComponent ?? suggestedFilename
    }

    var progressFraction: Double? {
        guard let expectedBytes, expectedBytes > 0 else {
            return nil
        }

        return min(max(Double(receivedBytes) / Double(expectedBytes), 0), 1)
    }

    var detailText: String {
        if let errorMessage, status == .failed {
            return errorMessage
        }

        if status == .inProgress {
            return "Downloading"
        }

        return destinationURL?.deletingLastPathComponent().path ?? status.label
    }
}

struct BrowserBookmark: Identifiable, Equatable {
    let id: UUID
    var title: String
    var url: URL
    var favicon: NSImage?
    var tabID: BrowserTab.ID?

    var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? url.host() ?? url.absoluteString
    }
}

struct BrowserHistorySuggestion: Identifiable, Equatable {
    var id: String { url.absoluteString }

    var title: String
    var url: URL
    var visitedAt: Date
    var favicon: NSImage?

    var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? url.host() ?? url.absoluteString
    }
}

struct BrowserConsoleMessage: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let level: String
    let message: String
    let url: String?
    let source: String
}

enum BrowserMediaDeviceKind: String, CaseIterable, Hashable {
    case camera
    case microphone

    var iconSystemName: String {
        switch self {
        case .camera:
            return "video.fill"
        case .microphone:
            return "mic.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .camera:
            return "Video Permission"
        case .microphone:
            return "Microphone Permission"
        }
    }
}

enum BrowserBezelStyle: String, CaseIterable, Equatable {
    case liquidGlass
    case simple

    var label: String {
        switch self {
        case .liquidGlass:
            return "Liquid Glass"
        case .simple:
            return "Simple"
        }
    }
}

struct BrowserMediaPermissionSnapshot: Equatable {
    var hasActivePage: Bool
    var isCameraAllowed: Bool
    var isMicrophoneAllowed: Bool

    func isAllowed(_ kind: BrowserMediaDeviceKind) -> Bool {
        switch kind {
        case .camera:
            return isCameraAllowed
        case .microphone:
            return isMicrophoneAllowed
        }
    }
}

enum BrowserToastKind: Equatable {
    case mediaPermission
    case download
}

enum BrowserToastStatus: Equatable {
    case pending
    case success
    case failure
}

struct BrowserToast: Identifiable, Equatable {
    let id: UUID
    let kind: BrowserToastKind
    var title: String
    var message: String
    var iconSystemName: String
    var status: BrowserToastStatus
    var progressFraction: Double?
    var downloadID: BrowserDownload.ID?
}

enum OriginSecurityState {
    case noPage
    case secure
    case local
    case insecure
    case certificateError

    var iconSystemName: String {
        switch self {
        case .noPage:
            return "globe"
        case .secure:
            return "lock.fill"
        case .local:
            return "desktopcomputer"
        case .insecure:
            return "exclamationmark.triangle.fill"
        case .certificateError:
            return "lock.trianglebadge.exclamationmark.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .noPage:
            return "No page loaded"
        case .secure:
            return "Secure HTTPS connection"
        case .local:
            return "Local HTTP connection"
        case .insecure:
            return "Not secure HTTP connection"
        case .certificateError:
            return "Certificate error"
        }
    }
}

@MainActor
final class BrowserState: NSObject, ObservableObject, WKUIDelegate, WKDownloadDelegate {
    private static let allowedURLSchemes: Set<String> = ["http", "https"]
    private static let allowedDownloadURLSchemes: Set<String> = ["http", "https", "blob", "data"]
    private static let consoleMessageLimit = 500

    @Published private(set) var tabs: [BrowserTab] = []
    @Published private(set) var bookmarks: [BrowserBookmark] = []
    @Published private(set) var historySuggestions: [BrowserHistorySuggestion] = []
    @Published private(set) var downloads: [BrowserDownload] = []
    @Published private(set) var consoleMessages: [BrowserConsoleMessage] = []
    @Published private(set) var toasts: [BrowserToast] = []
    @Published var selectedTabID: BrowserTab.ID?
    @Published private(set) var bezelStyle: BrowserBezelStyle = .liquidGlass
    @Published private var mountRequestedTabIDs: Set<BrowserTab.ID> = []
    @Published private var mediaPermissionDecisionsByOrigin: [String: [BrowserMediaDeviceKind: Bool]] = [:]
    @Published private(set) var isElementFullscreenActive = false

    private let database: BrowserDatabase?
    private var mountedTabIDs: Set<BrowserTab.ID> = []
    private var pendingTabLoads: [BrowserTab.ID: URL] = [:]
    private var bookmarkFaviconTasks: [BrowserBookmark.ID: Task<Void, Never>] = [:]
    private var downloadIDsByDownload: [ObjectIdentifier: BrowserDownload.ID] = [:]
    private var toastIDsByDownloadID: [BrowserDownload.ID: BrowserToast.ID] = [:]
    private var mediaPermissionRequests: [BrowserToast.ID: BrowserMediaPermissionRequest] = [:]
    private var toastDismissalTasks: [BrowserToast.ID: Task<Void, Never>] = [:]
    private var isRestoringSession = false

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

    override init() {
        do {
            database = try BrowserDatabase.openDefault()
        } catch {
            database = nil
            NSLog("Browser persistence disabled: \(error.localizedDescription)")
        }

        super.init()
        loadSettings()
        loadMediaPermissionDecisions()
        loadBookmarks()
        loadHistorySuggestions()
        loadDownloadHistory()
        restoreSessionOrCreateTab()
    }

    deinit {
        bookmarkFaviconTasks.values.forEach { $0.cancel() }
        toastDismissalTasks.values.forEach { $0.cancel() }
    }

    func newTab(url: URL? = nil) {
        guard url != nil else {
            return
        }

        let tab = makeTab()
        tabs.append(tab)
        selectedTabID = tab.id
        persistSession()

        if let url {
            load(url, in: tab)
        }
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
        guard let url = Self.url(from: address) else {
            return
        }

        if let activeTab {
            load(url, in: activeTab)
        } else {
            newTab(url: url)
        }
    }

    func openNewTab(from address: String) -> Bool {
        guard let url = Self.url(from: address) else {
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
              Self.isAllowedNavigationURL(url) else {
            return
        }

        if let bookmark = bookmark(for: url) {
            removeBookmark(id: bookmark.id)
            return
        }

        let bookmark = BrowserBookmark(
            id: UUID(),
            title: activeTab?.displayTitle ?? BrowserTab.defaultTitle(for: url),
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
              Self.isAllowedNavigationURL(url) else {
            return
        }

        clearBookmarkTabBinding(for: id)

        if let bookmarkIndex = bookmarks.firstIndex(where: { Self.isSameBookmarkPage($0.url, url) }) {
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
        do {
            try database?.saveSetting(key: "bezelStyle", value: style.rawValue)
        } catch {
            NSLog("Browser setting save failed: \(error.localizedDescription)")
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

    private func restoreSessionOrCreateTab() {
        guard let database else { return }

        do {
            guard let session = try database.loadDefaultSession(), !session.tabs.isEmpty else {
                return
            }

            isRestoringSession = true
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
            isRestoringSession = false
            persistSession()
        } catch {
            isRestoringSession = false
            NSLog("Browser session restore failed: \(error.localizedDescription)")
        }
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
        tab.onDiagnosticMessage = { [weak self] tab, level, message in
            self?.appendConsoleMessage(
                level: level,
                message: message,
                url: tab.webView.url?.absoluteString ?? tab.url?.absoluteString,
                source: "browser"
            )
        }

        return tab
    }

    private func configureWebViewConfiguration(_ configuration: WKWebViewConfiguration) {
        BrowserWebView.configure(configuration, consoleMessageHandler: BrowserConsoleScriptMessageHandler(browser: self))
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

    private func loadDownloadHistory() {
        do {
            downloads = try database?.loadRecentDownloads(limit: 50).map { download in
                guard download.status == .inProgress else {
                    return download
                }

                var interruptedDownload = download
                interruptedDownload.status = .failed
                interruptedDownload.finishedAt = Date()
                interruptedDownload.errorMessage = "Interrupted"
                try? database?.saveDownload(interruptedDownload)
                return interruptedDownload
            } ?? []
        } catch {
            NSLog("Browser downloads load failed: \(error.localizedDescription)")
        }
    }

    private func loadSettings() {
        do {
            let settings = try database?.loadSettings() ?? [:]
            if let rawBezelStyle = settings["bezelStyle"],
               let storedBezelStyle = BrowserBezelStyle(rawValue: rawBezelStyle) {
                bezelStyle = storedBezelStyle
            }
        } catch {
            NSLog("Browser settings load failed: \(error.localizedDescription)")
        }
    }

    private func loadMediaPermissionDecisions() {
        do {
            let storedDecisions = try database?.loadMediaPermissionDecisions() ?? []
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
        } catch {
            NSLog("Browser media permission decisions load failed: \(error.localizedDescription)")
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

        do {
            try database?.saveDownload(item)
        } catch {
            NSLog("Browser download save failed: \(error.localizedDescription)")
        }
    }

    private func persistMediaPermissionDecision(originKey: String, kind: BrowserMediaDeviceKind, isAllowed: Bool) {
        do {
            try database?.saveMediaPermissionDecision(
                origin: originKey,
                deviceKind: kind.rawValue,
                isAllowed: isAllowed
            )
        } catch {
            NSLog("Browser media permission decision save failed: \(error.localizedDescription)")
        }
    }

    private func uniqueDownloadURL(for suggestedFilename: String) -> URL {
        let fileManager = FileManager.default
        let downloadsDirectory = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
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

    private func sanitizedFilename(_ filename: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:")
            .union(.newlines)
            .union(.controlCharacters)
        let components = filename.components(separatedBy: invalidCharacters)
        return components.joined(separator: "-").nonEmpty ?? "Download"
    }

    private func load(_ url: URL, in tab: BrowserTab) {
        guard Self.isAllowedNavigationURL(url) else {
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

        do {
            try database?.recordHistoryVisit(url: url, title: tab.displayTitle, tabID: tab.id)
            loadHistorySuggestions()
        } catch {
            NSLog("Browser history record failed: \(error.localizedDescription)")
        }
    }

    private func refreshElementFullscreenState() {
        isElementFullscreenActive = tabs.contains { tab in
            tab.webView.fullscreenState == .enteringFullscreen || tab.webView.fullscreenState == .inFullscreen
        }
    }

    private func persistSession() {
        guard !isRestoringSession else {
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

        do {
            try database?.saveDefaultSession(tabs: snapshots, selectedTabID: persistedSelectedTabID)
        } catch {
            NSLog("Browser session save failed: \(error.localizedDescription)")
        }
    }

    private func loadBookmarks() {
        do {
            bookmarks = try database?.loadBookmarks().map { storedBookmark in
                BrowserBookmark(
                    id: storedBookmark.id,
                    title: storedBookmark.title,
                    url: storedBookmark.url,
                    favicon: nil,
                    tabID: nil
                )
            } ?? []
            bookmarks.forEach(loadBookmarkFaviconIfNeeded)
        } catch {
            NSLog("Browser bookmarks load failed: \(error.localizedDescription)")
        }
    }

    private func loadHistorySuggestions() {
        do {
            historySuggestions = try database?.loadRecentHistorySuggestions(limit: 80).compactMap { storedSuggestion in
                guard Self.isAllowedNavigationURL(storedSuggestion.url) else {
                    return nil
                }

                return BrowserHistorySuggestion(
                    title: storedSuggestion.title,
                    url: storedSuggestion.url,
                    visitedAt: storedSuggestion.visitedAt,
                    favicon: storedSuggestion.faviconData.flatMap(NSImage.init(data:))
                )
            } ?? []
        } catch {
            NSLog("Browser history suggestions load failed: \(error.localizedDescription)")
        }
    }

    private func tabFaviconDidLoad(_ tab: BrowserTab, favicon: NSImage) {
        guard let pageURL = tab.url,
              let origin = Self.originKey(for: pageURL),
              let imageData = favicon.tiffRepresentation else {
            return
        }

        do {
            try database?.saveFavicon(origin: origin, pageURL: pageURL, imageData: imageData)
            loadHistorySuggestions()
        } catch {
            NSLog("Browser favicon save failed: \(error.localizedDescription)")
        }
    }

    private func persistBookmark(_ bookmark: BrowserBookmark, position: Int) {
        do {
            try database?.saveBookmark(bookmark, position: position)
        } catch {
            NSLog("Browser bookmark save failed: \(error.localizedDescription)")
        }
    }

    private func removeBookmark(id: BrowserBookmark.ID) {
        bookmarkFaviconTasks[id]?.cancel()
        bookmarkFaviconTasks.removeValue(forKey: id)
        if bookmarks.contains(where: { $0.id == id }) {
            objectWillChange.send()
        }
        bookmarks.removeAll { $0.id == id }

        do {
            try database?.deleteBookmark(id: id)
            for (index, bookmark) in bookmarks.enumerated() {
                try database?.saveBookmark(bookmark, position: index)
            }
        } catch {
            NSLog("Browser bookmark delete failed: \(error.localizedDescription)")
        }
    }

    private func bookmark(for url: URL) -> BrowserBookmark? {
        bookmarks.first { Self.isSameBookmarkPage($0.url, url) }
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

        return Self.originKey(for: url)
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

    private static func originKey(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host()?.lowercased() else {
            return nil
        }

        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
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

    fileprivate static func isAllowedNavigationURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }

        return allowedURLSchemes.contains(scheme)
    }

    fileprivate static func isAllowedDownloadURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }

        return allowedDownloadURLSchemes.contains(scheme)
    }

    fileprivate static func originSecurityState(for url: URL?) -> OriginSecurityState {
        guard let url, let scheme = url.scheme?.lowercased() else {
            return .noPage
        }

        switch scheme {
        case "https":
            return .secure
        case "http":
            return isLocalURL(url) ? .local : .insecure
        default:
            return .noPage
        }
    }

    private static func isLocalURL(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else {
            return false
        }

        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static func url(from address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.contains("://"), let url = URL(string: trimmed) {
            return isAllowedNavigationURL(url) ? url : nil
        }

        if !trimmed.contains(where: \.isWhitespace),
           let components = URLComponents(string: "https://\(trimmed)"),
           let host = components.host,
           host.contains(".") || host == "localhost",
           let url = components.url,
           isAllowedNavigationURL(url) {
            return components.url
        }

        var searchComponents = URLComponents(string: "https://www.google.com/search")!
        searchComponents.queryItems = [
            URLQueryItem(name: "q", value: trimmed)
        ]
        return searchComponents.url
    }

    fileprivate static func isSameBookmarkPage(_ lhs: URL, _ rhs: URL) -> Bool {
        normalizedBookmarkPage(lhs) == normalizedBookmarkPage(rhs)
    }

    private static func normalizedBookmarkPage(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil

        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }

        return components.url?.absoluteString ?? url.absoluteString
    }
}

private struct BrowserMediaPermissionRequest {
    let originKey: String
    let deviceKinds: Set<BrowserMediaDeviceKind>
    let handler: (WKPermissionDecision) -> Void
}

@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate {
    let id: UUID
    let webView: BrowserWebView

    @Published private(set) var title = "New Tab"
    @Published private(set) var url: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var originSecurityState: OriginSecurityState = .noPage
    @Published private(set) var favicon: NSImage?

    var onStateDidChange: ((BrowserTab) -> Void)?
    var onNavigationDidFinish: ((BrowserTab) -> Void)?
    var onFaviconDidLoad: ((BrowserTab, NSImage) -> Void)?
    var onFullscreenStateDidChange: ((BrowserTab) -> Void)?
    var onDownloadDidBegin: ((BrowserTab, WKDownload, URL?) -> Void)?
    var onDiagnosticMessage: ((BrowserTab, String, String) -> Void)?

    private var fullscreenObservation: NSKeyValueObservation?
    private var faviconLoadTask: Task<Void, Never>?
    private var faviconRequestID: UUID?

    var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Tab" : title
    }

    var displaySubtitle: String {
        url?.absoluteString ?? "No page loaded"
    }

    var addressText: String {
        url?.absoluteString ?? ""
    }

    var displayAddressText: String {
        guard let url else {
            return ""
        }

        return Self.displayAddressText(for: url)
    }

    init(
        id: UUID = UUID(),
        webView: BrowserWebView = BrowserWebView(frame: .zero, configuration: BrowserWebView.makeConfiguration()),
        title: String = "New Tab",
        url: URL? = nil
    ) {
        self.id = id
        self.webView = webView
        super.init()

        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.defaultTitle(for: url) : title
        self.url = url

        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .clear
        fullscreenObservation = webView.observe(\.fullscreenState, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else {
                    return
                }

                self.onFullscreenStateDidChange?(self)
            }
        }
        refreshFromWebView(notify: false)
    }

    deinit {
        faviconLoadTask?.cancel()
    }

    func attachUIDelegate(_ delegate: WKUIDelegate) {
        webView.uiDelegate = delegate
    }

    func prepareDeferredLoad(_ url: URL) {
        guard BrowserState.isAllowedNavigationURL(url) else {
            return
        }

        self.url = url
        title = Self.defaultTitle(for: url)
        isLoading = false
        originSecurityState = BrowserState.originSecurityState(for: url)
        clearFavicon()
        onStateDidChange?(self)
    }

    func load(_ url: URL) {
        guard BrowserState.isAllowedNavigationURL(url) else {
            return
        }

        self.url = url
        title = Self.defaultTitle(for: url)
        isLoading = true
        originSecurityState = BrowserState.originSecurityState(for: url)
        clearFavicon()
        webView.load(URLRequest(url: url))
        refreshFromWebView()
    }

    func goBack() {
        guard webView.canGoBack else {
            return
        }

        webView.goBack()
        refreshFromWebView()
    }

    func goForward() {
        guard webView.canGoForward else {
            return
        }

        webView.goForward()
        refreshFromWebView()
    }

    func reloadOrStop() {
        if webView.isLoading {
            webView.stopLoading()
        } else {
            webView.reload()
        }

        refreshFromWebView()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        originSecurityState = BrowserState.originSecurityState(for: webView.url ?? url)
        logGoogleDiagnostic(level: "debug", "didStartProvisionalNavigation url=\((webView.url ?? url)?.absoluteString ?? "nil")")
        refreshFromWebView()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        logGoogleDiagnostic(level: "debug", "didCommit url=\((webView.url ?? url)?.absoluteString ?? "nil")")
        refreshFromWebView()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshFromWebView()
        logGoogleDiagnostic(level: "debug", "didFinish title=\(displayTitle) url=\((webView.url ?? url)?.absoluteString ?? "nil")")
        refreshFavicon()
        onNavigationDidFinish?(self)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        updateOriginSecurityState(after: error)
        logGoogleDiagnostic(level: "error", "didFail error=\(error.localizedDescription) url=\((webView.url ?? url)?.absoluteString ?? "nil")")
        refreshFromWebView()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        updateOriginSecurityState(after: error)
        logGoogleDiagnostic(level: "error", "didFailProvisionalNavigation error=\(error.localizedDescription) url=\((webView.url ?? url)?.absoluteString ?? "nil")")
        refreshFromWebView()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        refreshFromWebView()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        if shouldReloadWithDesktopUserAgent(navigationAction) {
            webView.load(Self.desktopUserAgentRequest(from: navigationAction.request))
            decisionHandler(.cancel)
            return
        }

        if Self.isGoogleURL(url) {
            let headers = navigationAction.request.allHTTPHeaderFields ?? [:]
            logGoogleDiagnostic(
                level: "debug",
                "request method=\(navigationAction.request.httpMethod ?? "GET") url=\(url.absoluteString) targetFrameMain=\(navigationAction.targetFrame?.isMainFrame.description ?? "nil") headers=\(Self.formattedHeaders(headers))"
            )
        }

        if navigationAction.shouldPerformDownload {
            decisionHandler(BrowserState.isAllowedDownloadURL(url) ? .download : .cancel)
            return
        }

        guard BrowserState.isAllowedNavigationURL(url) else {
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    private func shouldReloadWithDesktopUserAgent(_ navigationAction: WKNavigationAction) -> Bool {
        guard navigationAction.targetFrame?.isMainFrame == true,
              let url = navigationAction.request.url,
              BrowserState.isAllowedNavigationURL(url) else {
            return false
        }

        let method = navigationAction.request.httpMethod?.uppercased() ?? "GET"
        guard method == "GET" || method == "HEAD" else {
            return false
        }

        let userAgent = navigationAction.request.value(forHTTPHeaderField: "User-Agent") ?? ""
        return !userAgent.contains(BrowserWebView.safariUserAgentSuffix)
    }

    private static func desktopUserAgentRequest(from request: URLRequest) -> URLRequest {
        var request = request
        request.setValue(BrowserWebView.desktopSafariUserAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        if let response = navigationResponse.response as? HTTPURLResponse,
           let url = response.url,
           Self.isGoogleURL(url) {
            logGoogleDiagnostic(
                level: "debug",
                "response status=\(response.statusCode) url=\(url.absoluteString) mime=\(response.mimeType ?? "nil") headers=\(Self.formattedHeaders(response.allHeaderFields))"
            )
        }

        if navigationResponse.canShowMIMEType {
            decisionHandler(.allow)
            return
        }

        guard let url = navigationResponse.response.url,
              BrowserState.isAllowedDownloadURL(url) else {
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.download)
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        onDownloadDidBegin?(self, download, navigationAction.request.url)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        onDownloadDidBegin?(self, download, navigationResponse.response.url)
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            originSecurityState = .certificateError
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        var trustError: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &trustError) else {
            originSecurityState = .certificateError
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        originSecurityState = BrowserState.originSecurityState(for: webView.url ?? url)
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }

    private func logGoogleDiagnostic(level: String, _ message: String) {
        guard Self.isGoogleURL(webView.url ?? url) || message.contains("google.") else {
            return
        }

        onDiagnosticMessage?(self, level, "[Google] \(message)")
    }

    private static func isGoogleURL(_ url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased() else {
            return false
        }

        return host == "google.com" || host.hasSuffix(".google.com")
    }

    private static func formattedHeaders<Key: Hashable, Value>(_ headers: [Key: Value]) -> String {
        headers
            .map { key, value in "\(key): \(value)" }
            .sorted()
            .joined(separator: "; ")
    }

    private func refreshFromWebView(notify: Bool = true) {
        url = webView.url ?? url

        if let webTitle = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines), !webTitle.isEmpty {
            title = webTitle
        } else if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title == "New Tab" {
            title = Self.defaultTitle(for: url)
        }

        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        if originSecurityState != .certificateError {
            originSecurityState = BrowserState.originSecurityState(for: webView.url ?? url)
        }

        if notify {
            onStateDidChange?(self)
        }
    }

    private func clearFavicon() {
        faviconLoadTask?.cancel()
        faviconLoadTask = nil
        faviconRequestID = nil
        favicon = nil
    }

    private func refreshFavicon() {
        guard let pageURL = webView.url ?? url,
              BrowserState.isAllowedNavigationURL(pageURL) else {
            clearFavicon()
            return
        }

        faviconLoadTask?.cancel()
        favicon = nil

        let requestID = UUID()
        faviconRequestID = requestID
        faviconLoadTask = Task { [weak self] in
            await self?.loadFavicon(for: pageURL, requestID: requestID)
        }
    }

    private func loadFavicon(for pageURL: URL, requestID: UUID) async {
        guard let image = await Self.fetchFavicon(for: pageURL, webView: webView),
              faviconRequestID == requestID else {
            if faviconRequestID == requestID {
                favicon = nil
            }
            return
        }

        favicon = image
        onFaviconDidLoad?(self, image)
    }

    fileprivate static func fetchFavicon(for pageURL: URL, webView: WKWebView?) async -> NSImage? {
        let candidates = await faviconCandidateURLs(for: pageURL, webView: webView)

        for candidate in candidates {
            guard !Task.isCancelled else {
                return nil
            }

            do {
                var request = URLRequest(url: candidate)
                request.cachePolicy = .returnCacheDataElseLoad
                request.timeoutInterval = 8

                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled else {
                    return nil
                }

                if let httpResponse = response as? HTTPURLResponse,
                   !(200..<300).contains(httpResponse.statusCode) {
                    continue
                }

                guard let image = NSImage(data: data), image.isValid else {
                    continue
                }

                return image
            } catch {
                continue
            }
        }

        return nil
    }

    private static func faviconCandidateURLs(for pageURL: URL, webView: WKWebView?) async -> [URL] {
        var urls: [URL] = []
        let script = """
        (() => Array.from(document.querySelectorAll('link[rel]'))
            .filter((link) => link.rel && link.rel.toLowerCase().includes('icon'))
            .map((link) => link.href)
            .filter(Boolean))()
        """

        if let webView,
           let rawIconURLs = try? await webView.evaluateJavaScript(script) as? [String] {
            urls.append(contentsOf: rawIconURLs.compactMap(URL.init(string:)))
        }

        if let fallbackURL = Self.defaultFaviconURL(for: pageURL) {
            urls.append(fallbackURL)
        }

        var seen = Set<String>()
        return urls.filter { url in
            guard BrowserState.isAllowedNavigationURL(url) else {
                return false
            }

            return seen.insert(url.absoluteString).inserted
        }
    }

    private static func defaultFaviconURL(for pageURL: URL) -> URL? {
        guard var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false),
              components.host != nil else {
            return nil
        }

        components.path = "/favicon.ico"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    fileprivate static func defaultTitle(for url: URL?) -> String {
        if let host = url?.host(), !host.isEmpty {
            return host
        }

        return "New Tab"
    }

    private static func displayAddressText(for url: URL) -> String {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return url.absoluteString
        }

        var displayText = url.absoluteString

        if let schemeRange = displayText.range(of: "\(scheme)://", options: [.caseInsensitive, .anchored]) {
            displayText.removeSubrange(schemeRange)
        }

        if let wwwRange = displayText.range(of: "www.", options: [.caseInsensitive, .anchored]) {
            displayText.removeSubrange(wwwRange)
        }

        return displayText
    }

    private func updateOriginSecurityState(after error: Error) {
        let nsError = error as NSError
        let certificateErrorCodes: Set<Int> = [
            NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateNotYetValid,
            NSURLErrorClientCertificateRejected,
            NSURLErrorClientCertificateRequired,
            NSURLErrorSecureConnectionFailed
        ]

        if nsError.domain == NSURLErrorDomain, certificateErrorCodes.contains(nsError.code) {
            originSecurityState = .certificateError
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
