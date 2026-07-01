import Foundation

enum BrowserInternalPage: String, CaseIterable, Equatable, Sendable {
    case settings
    case history
    case mail
    case dashboard
    case calendar

    static let scheme = "browser"

    var url: URL {
        URL(string: "\(Self.scheme)://\(rawValue)")!
    }

    var title: String {
        switch self {
        case .settings:
            return "Settings"
        case .history:
            return "History"
        case .mail:
            return "Mail"
        case .dashboard:
            return "Dashboard"
        case .calendar:
            return "Calendar"
        }
    }

    var iconSystemName: String {
        switch self {
        case .settings:
            return "gearshape"
        case .history:
            return "clock.arrow.circlepath"
        case .mail:
            return "envelope"
        case .dashboard:
            return "square.grid.2x2"
        case .calendar:
            return "calendar"
        }
    }

    static func page(for url: URL?) -> BrowserInternalPage? {
        guard let url,
              url.scheme?.lowercased() == scheme else {
            return nil
        }

        let host = url.host()?.lowercased()
        let path = url.path
            .split(separator: "/")
            .first
            .map(String.init)?
            .lowercased()
        let rawPage = host?.isEmpty == false ? host : path

        switch rawPage {
        case "settings", "preferences":
            return .settings
        case "history":
            return .history
        case "mail", "email":
            return .mail
        case "dashboard", "mail-dashboard", "email-dashboard":
            return .dashboard
        case "calendar", "calendars":
            return .calendar
        default:
            return nil
        }
    }

    static func url(from address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        guard lowercased == scheme || lowercased.hasPrefix("\(scheme)://") else {
            return nil
        }

        if let url = URL(string: trimmed), page(for: url) != nil {
            return url
        }

        return nil
    }
}
