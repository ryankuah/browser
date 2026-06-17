import Foundation
import WebKit

@MainActor
final class BrowserState: ObservableObject {
    @Published private(set) var tabs: [BrowserTab] = []
    @Published var selectedTabID: BrowserTab.ID?

    var activeTab: BrowserTab? {
        tabs.first { $0.id == selectedTabID }
    }

    init() {
        newTab()
    }

    func newTab(url: URL? = nil) {
        let tab = BrowserTab(url: url)
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func closeTab(id: BrowserTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return
        }

        let wasSelected = selectedTabID == id
        tabs.remove(at: index)

        if tabs.isEmpty {
            newTab()
            return
        }

        if wasSelected {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    func selectTab(id: BrowserTab.ID) {
        guard tabs.contains(where: { $0.id == id }) else {
            return
        }

        selectedTabID = id
    }

    func loadAddress(_ address: String) {
        guard let url = Self.url(from: address) else {
            return
        }

        activeTab?.load(url)
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

    private static func url(from address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.contains("://"), let url = URL(string: trimmed) {
            return url
        }

        if !trimmed.contains(where: \.isWhitespace),
           let components = URLComponents(string: "https://\(trimmed)"),
           let host = components.host,
           host.contains(".") || host == "localhost" {
            return components.url
        }

        var searchComponents = URLComponents(string: "https://duckduckgo.com/")!
        searchComponents.queryItems = [
            URLQueryItem(name: "q", value: trimmed)
        ]
        return searchComponents.url
    }
}

@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate {
    let id = UUID()
    let webView: BrowserWebView

    @Published private(set) var title = "New Tab"
    @Published private(set) var url: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    var displayTitle: String {
        title
    }

    var displaySubtitle: String {
        url?.absoluteString ?? "No page loaded"
    }

    var addressText: String {
        url?.absoluteString ?? ""
    }

    init(url initialURL: URL? = nil) {
        webView = BrowserWebView(frame: .zero, configuration: BrowserWebView.makeConfiguration())
        super.init()

        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .clear

        if let initialURL {
            load(initialURL)
        } else {
            refreshFromWebView()
        }
    }

    func load(_ url: URL) {
        self.url = url
        isLoading = true
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
        refreshFromWebView()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        refreshFromWebView()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshFromWebView()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        refreshFromWebView()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        refreshFromWebView()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        refreshFromWebView()
    }

    private func refreshFromWebView() {
        url = webView.url ?? url
        title = resolvedTitle()
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    private func resolvedTitle() -> String {
        if let title = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }

        if let host = url?.host(), !host.isEmpty {
            return host
        }

        return "New Tab"
    }
}
