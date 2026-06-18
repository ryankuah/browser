import AppKit
import Foundation

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

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
