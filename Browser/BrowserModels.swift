import AppKit
import Foundation

private func browserDisplayTitle(_ title: String, fallback: @autoclosure () -> String) -> String {
    title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? fallback()
}

private func browserDisplayTitle(_ title: String, url: URL) -> String {
    browserDisplayTitle(title, fallback: url.host() ?? url.absoluteString)
}

enum BrowserSearchEngine: String, CaseIterable, Equatable, Sendable {
    case google
    case duckDuckGo
    case brave

    var label: String {
        switch self {
        case .google:
            return "Google"
        case .duckDuckGo:
            return "DuckDuckGo"
        case .brave:
            return "Brave"
        }
    }

    func searchURL(for query: String) -> URL? {
        var components: URLComponents

        switch self {
        case .google:
            components = URLComponents(string: "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case .duckDuckGo:
            components = URLComponents(string: "https://duckduckgo.com/")!
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case .brave:
            components = URLComponents(string: "https://search.brave.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        }

        return components.url
    }
}

enum BrowserUserScriptInjectionTime: String, CaseIterable, Equatable, Sendable {
    case documentStart
    case documentEnd

    var label: String {
        switch self {
        case .documentStart:
            return "Document Start"
        case .documentEnd:
            return "Document End"
        }
    }
}

struct BrowserUserScript: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var matchPatterns: String
    var source: String
    var isEnabled: Bool
    var injectionTime: BrowserUserScriptInjectionTime
    var forMainFrameOnly: Bool
    var position: Int

    static let defaultMatchPatterns = "<all_urls>"
    static let defaultSource = """
    // JavaScript runs on pages matched above.
    """

    var displayName: String {
        browserDisplayTitle(name, fallback: "User Script")
    }

    var normalizedMatchPatternLines: [String] {
        matchPatterns
            .components(separatedBy: CharacterSet(charactersIn: "\n,"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var isRunnable: Bool {
        isEnabled &&
        !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !normalizedMatchPatternLines.isEmpty
    }
}

enum BrowserDownloadStatus: Equatable, Sendable {
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

struct BrowserDownload: Identifiable, Equatable, Sendable {
    let id: UUID
    let sourceURL: URL?
    var destinationURL: URL?
    var suggestedFilename: String
    var receivedBytes: Int64
    var expectedBytes: Int64?
    var speedBytesPerSecond: Int64? = nil
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
            return inProgressDetailText
        }

        if receivedBytes > 0 {
            return "\(Self.formattedBytes(receivedBytes)) • \(destinationURL?.deletingLastPathComponent().path ?? status.label)"
        }

        return destinationURL?.deletingLastPathComponent().path ?? status.label
    }

    var canCancel: Bool {
        status == .inProgress
    }

    var canRetry: Bool {
        guard status == .failed, let sourceURL else {
            return false
        }

        return BrowserNavigation.isAllowedNavigationURL(sourceURL)
    }

    private var inProgressDetailText: String {
        var components: [String] = []

        if let expectedBytes, expectedBytes > 0 {
            components.append("\(Self.formattedBytes(receivedBytes)) of \(Self.formattedBytes(expectedBytes))")
            if let progressFraction {
                components.append(Self.formattedPercent(progressFraction))
            }
        } else if receivedBytes > 0 {
            components.append(Self.formattedBytes(receivedBytes))
        } else {
            components.append("Downloading")
        }

        if let speedBytesPerSecond, speedBytesPerSecond > 0 {
            components.append("\(Self.formattedBytes(speedBytesPerSecond))/s")
        }

        return components.joined(separator: " • ")
    }

    private static func formattedBytes(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    private static func formattedPercent(_ fraction: Double) -> String {
        let percent = Int((fraction * 100).rounded())
        return "\(percent)%"
    }
}

struct BrowserBookmark: Identifiable, Equatable {
    let id: UUID
    var title: String
    var url: URL
    var favicon: NSImage?
    var tabID: BrowserTab.ID?

    var displayTitle: String {
        browserDisplayTitle(title, url: url)
    }
}

struct BrowserProfile: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var colorHex: String
    var position: Int

    static let defaultColorHex = "#2F80ED"
    static let lightPresetColorHexes = [
        "#F8FAFC",
        "#FDE68A",
        "#BFDBFE",
        "#BBF7D0",
        "#FBCFE8",
        "#FED7AA",
        "#DDD6FE",
        "#CCFBF1"
    ]
    static let darkPresetColorHexes = [
        "#111827",
        "#2F80ED",
        "#047857",
        "#B91C1C",
        "#6D28D9",
        "#0F766E",
        "#A16207",
        "#BE185D"
    ]

    var displayName: String {
        browserDisplayTitle(name, fallback: "Profile")
    }
}

struct BrowserHistoryEntry: Identifiable, Equatable {
    var id: String { url.absoluteString }

    var title: String
    var url: URL
    var lastVisitedAt: Date
    var visitCount: Int
    var favicon: NSImage?

    var displayTitle: String {
        browserDisplayTitle(title, url: url)
    }

    var displayURL: String {
        BrowserNavigation.displayAddressText(for: url)
    }
}

struct BrowserHistoryVisit: Identifiable, Equatable {
    let id: Int64
    var title: String
    var url: URL
    var visitedAt: Date
    var favicon: NSImage?

    var displayTitle: String {
        browserDisplayTitle(title, url: url)
    }

    var displayURL: String {
        BrowserNavigation.displayAddressText(for: url)
    }
}

struct BrowserHistoryTreeNode: Identifiable, Equatable {
    let id: Int64
    var title: String
    var url: URL
    var visitedAt: Date
    var favicon: NSImage?
    var children: [BrowserHistoryTreeNode] = []

    var displayTitle: String {
        browserDisplayTitle(title, url: url)
    }

    var displayURL: String {
        BrowserNavigation.displayAddressText(for: url)
    }
}

struct BrowserHistoryJourney: Identifiable, Equatable {
    let id: UUID
    var title: String
    var startedAt: Date
    var lastVisitedAt: Date
    var roots: [BrowserHistoryTreeNode]

    var displayTitle: String {
        browserDisplayTitle(title, fallback: "New Tab")
    }
}

struct BrowserZoomHUD: Identifiable, Equatable {
    let id = UUID()
    let percentText: String
}

struct BrowserAutocompleteSite: Identifiable, Equatable {
    var id: String { host }

    var host: String
    var registrableDomain: String
    var subdomain: String?
    var title: String
    var url: URL
    var visitCount: Int
    var lastVisitedAt: Date
    var favicon: NSImage?

    var displayTitle: String {
        browserDisplayTitle(title, fallback: host)
    }

    var displayURL: String {
        host
    }
}

struct BrowserAutocompletePage: Identifiable, Equatable {
    var id: String { url.absoluteString }

    var url: URL
    var title: String
    var host: String
    var registrableDomain: String
    var subdomain: String?
    var visitCount: Int
    var lastVisitedAt: Date
    var favicon: NSImage?

    var displayTitle: String {
        browserDisplayTitle(title, url: url)
    }

    var displayURL: String {
        BrowserNavigation.displayAddressText(for: url)
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

extension NSColor {
    convenience init?(hexString: String) {
        var value = hexString.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.hasPrefix("#") {
            value.removeFirst()
        }

        guard value.count == 6,
              let integer = UInt32(value, radix: 16) else {
            return nil
        }

        self.init(
            calibratedRed: CGFloat((integer >> 16) & 0xFF) / 255,
            green: CGFloat((integer >> 8) & 0xFF) / 255,
            blue: CGFloat(integer & 0xFF) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        let red = Int(round(max(0, min(1, color.redComponent)) * 255))
        let green = Int(round(max(0, min(1, color.greenComponent)) * 255))
        let blue = Int(round(max(0, min(1, color.blueComponent)) * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    var prefersDarkForeground: Bool {
        let color = usingColorSpace(.sRGB) ?? self
        func linearized(_ component: CGFloat) -> CGFloat {
            component <= 0.03928
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }

        let luminance = (0.2126 * linearized(color.redComponent))
            + (0.7152 * linearized(color.greenComponent))
            + (0.0722 * linearized(color.blueComponent))
        return luminance > 0.56
    }
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

struct BrowserPageFailure: Equatable {
    let url: URL?
    let title: String
    let message: String
    let detail: String
    let isCertificateError: Bool

    static func navigationFailure(url: URL?, error: Error, isCertificateError: Bool) -> BrowserPageFailure {
        let nsError = error as NSError
        let title: String
        let message: String

        if isCertificateError {
            title = "Certificate Error"
            message = "Browser could not verify this page's identity."
        } else {
            let copy = navigationFailureCopy(for: nsError, url: url)
            title = copy.title
            message = copy.message
        }
        let detail = "\(nsError.domain) \(nsError.code)"

        return BrowserPageFailure(
            url: url,
            title: title,
            message: message,
            detail: detail,
            isCertificateError: isCertificateError
        )
    }

    private static func navigationFailureCopy(for error: NSError, url: URL?) -> (title: String, message: String) {
        guard error.domain == NSURLErrorDomain else {
            return ("Page Failed to Load", error.localizedDescription)
        }

        switch error.code {
        case NSURLErrorCannotConnectToHost:
            if let url, BrowserNavigation.isLocalURL(url) {
                return (
                    "Can't Connect to Localhost",
                    "Nothing is responding at this address. Check that your local server is running and that the port is correct."
                )
            }

            return (
                "Can't Connect",
                "The server is not accepting connections right now."
            )
        case NSURLErrorNotConnectedToInternet:
            return (
                "No Internet Connection",
                "Your Mac appears to be offline."
            )
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return (
                "Server Not Found",
                "Browser could not find the server for this address."
            )
        case NSURLErrorTimedOut:
            return (
                "Connection Timed Out",
                "The server took too long to respond."
            )
        case NSURLErrorSecureConnectionFailed:
            return (
                "Secure Connection Failed",
                "Browser could not establish a secure connection to this page."
            )
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return (
                "HTTP Blocked",
                "This page requires a secure HTTPS connection."
            )
        default:
            return ("Page Failed to Load", error.localizedDescription)
        }
    }

    static func certificateFailure(url: URL?) -> BrowserPageFailure {
        BrowserPageFailure(
            url: url,
            title: "Certificate Error",
            message: "Browser could not verify this page's identity.",
            detail: "The secure connection was rejected before the page loaded.",
            isCertificateError: true
        )
    }

    static func webContentProcessTerminated(url: URL?) -> BrowserPageFailure {
        BrowserPageFailure(
            url: url,
            title: "Page Stopped Responding",
            message: "The web content process closed unexpectedly.",
            detail: "Reload the page to start a fresh web content process.",
            isCertificateError: false
        )
    }

    static func httpFailure(url: URL?, statusCode: Int) -> BrowserPageFailure {
        let title: String
        let message: String

        switch statusCode {
        case 404:
            title = "Page Not Found"
            message = "The server could not find a page at this address."
        case 500...599:
            title = "Server Error"
            message = "The server returned an error instead of the page."
        default:
            title = "Page Failed to Load"
            message = "The server returned an HTTP error for this address."
        }

        return BrowserPageFailure(
            url: url,
            title: title,
            message: message,
            detail: "HTTP \(statusCode)",
            isCertificateError: false
        )
    }
}

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var removingWWWPrefix: String {
        var value = self
        while value.hasPrefix("www.") {
            value.removeFirst(4)
        }
        return value
    }
}
