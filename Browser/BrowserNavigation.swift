import Foundation

enum BrowserNavigation {
    private static let allowedURLSchemes: Set<String> = ["http", "https"]
    private static let allowedDownloadURLSchemes: Set<String> = ["http", "https", "blob", "data"]
    private static let googleOAuthHosts: Set<String> = ["accounts.google.com", "neat-mongoose-389.convex.site"]
    static let browserCallbackScheme = "com.ryankuah.browser"

    static func url(from address: String, searchEngine: BrowserSearchEngine) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return nil
        }

        if let internalURL = BrowserInternalPage.url(from: trimmed) {
            return internalURL
        }

        if trimmed.contains("://"), let url = URL(string: trimmed) {
            return isAllowedNavigationURL(url) ? url : nil
        }

        if !trimmed.contains(where: \.isWhitespace),
           let parsedComponents = URLComponents(string: "https://\(trimmed)"),
           let host = parsedComponents.host,
           host.contains(".") || isLocalHost(host),
           let url = urlForSchemlessAddress(trimmed, host: host),
           isAllowedNavigationURL(url) {
            return url
        }

        return searchEngine.searchURL(for: trimmed)
    }

    private static func urlForSchemlessAddress(_ address: String, host: String) -> URL? {
        let scheme = isLocalHost(host) ? "http" : "https"

        guard let components = URLComponents(string: "\(scheme)://\(address)") else {
            return nil
        }

        return components.url
    }

    static func isAllowedNavigationURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }

        return allowedURLSchemes.contains(scheme) || BrowserInternalPage.page(for: url) != nil
    }

    static func isInternalPageURL(_ url: URL?) -> Bool {
        BrowserInternalPage.page(for: url) != nil
    }

    static func isBrowserCallbackURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == browserCallbackScheme
    }

    static func isTransientOAuthURL(_ url: URL) -> Bool {
        if isBrowserCallbackURL(url) {
            return true
        }

        guard let host = url.host()?.lowercased() else {
            return false
        }

        if host == "accounts.google.com", url.path.contains("/o/oauth") {
            return true
        }

        return isGoogleOAuthCallbackURL(url)
    }

    static func isGoogleOAuthCallbackURL(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else {
            return false
        }

        return googleOAuthHosts.contains(host) && url.path == "/api/google/oauth/callback"
    }

    static func isAllowedDownloadURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }

        return allowedDownloadURLSchemes.contains(scheme)
    }

    static func originSecurityState(for url: URL?) -> OriginSecurityState {
        guard let url, let scheme = url.scheme?.lowercased() else {
            return .noPage
        }

        switch scheme {
        case BrowserInternalPage.scheme:
            return .noPage
        case "https":
            return .secure
        case "http":
            return isLocalURL(url) ? .local : .insecure
        default:
            return .noPage
        }
    }

    static func originKey(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host()?.lowercased() else {
            return nil
        }

        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    static func isSameBookmarkPage(_ lhs: URL, _ rhs: URL) -> Bool {
        normalizedBookmarkPage(lhs) == normalizedBookmarkPage(rhs)
    }

    static func defaultTitle(for url: URL?) -> String {
        if let page = BrowserInternalPage.page(for: url) {
            return page.title
        }

        if let host = url?.host(), !host.isEmpty {
            return host
        }

        return "New Tab"
    }

    static func displayAddressText(for url: URL) -> String {
        if BrowserInternalPage.page(for: url) != nil {
            return url.absoluteString
        }

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

    static func isLocalURL(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else {
            return false
        }

        return isLocalHost(host)
    }

    private static func isLocalHost(_ host: String) -> Bool {
        switch host.lowercased() {
        case "localhost", "127.0.0.1", "::1", "0.0.0.0":
            return true
        default:
            return false
        }
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
