import AppKit
import Foundation

@MainActor
final class BrowserExternalURLRouter: ObservableObject {
    static let shared = BrowserExternalURLRouter()

    private final class Registration {
        let id: UUID
        weak var browser: BrowserState?
        weak var window: NSWindow?
        var updatedAt: Date

        init(id: UUID, browser: BrowserState, window: NSWindow) {
            self.id = id
            self.browser = browser
            self.window = window
            updatedAt = Date()
        }
    }

    private var registrations: [Registration] = []
    private var pendingURLs: [URL] = []
    private var pendingCallbackURLs: [URL] = []
    private weak var primaryWindow: NSWindow?
    private weak var session: BrowserSessionController?

    private init() {}

    func registerSession(_ session: BrowserSessionController) {
        self.session = session
        drainPendingCallbackURLs()
    }

    func registerApplicationWindow(_ window: NSWindow) {
        pruneRegistrations()

        if let primaryWindow, primaryWindow !== window {
            focus(primaryWindow)
            closeDuplicate(window)
            return
        }

        primaryWindow = window
    }

    func register(browser: BrowserState, window: NSWindow, existingID: UUID?) -> UUID? {
        pruneRegistrations()

        if let existingID,
           let registration = registrations.first(where: { $0.id == existingID }) {
            registration.browser = browser
            registration.window = window
            registration.updatedAt = Date()
            primaryWindow = window
            drainPendingURLs(to: registration)
            return existingID
        }

        if let existingRegistration = preferredRegistration,
           existingRegistration.window !== window {
            drainPendingURLs(to: existingRegistration)
            focus(existingRegistration.window)
            closeDuplicate(window)
            return nil
        }

        if let primaryWindow, primaryWindow !== window {
            focus(primaryWindow)
            closeDuplicate(window)
            return nil
        }

        let registration = Registration(id: existingID ?? UUID(), browser: browser, window: window)
        registrations.append(registration)
        primaryWindow = window
        drainPendingURLs(to: registration)
        return registration.id
    }

    func unregister(id: UUID?) {
        guard let id else {
            return
        }

        registrations.removeAll { $0.id == id }
    }

    func openExternalURL(_ url: URL) {
        if BrowserNavigation.isBrowserCallbackURL(url) {
            openBrowserCallbackURL(url)
            return
        }

        guard BrowserNavigation.isAllowedNavigationURL(url) else {
            return
        }

        pruneRegistrations()

        guard let registration = preferredRegistration else {
            pendingURLs.append(url)
            return
        }

        open(url, in: registration)
    }

    func focusExistingWindow() -> Bool {
        pruneRegistrations()

        guard let window = preferredRegistration?.window else {
            guard let primaryWindow else {
                return false
            }

            focus(primaryWindow)
            return true
        }

        focus(window)
        return true
    }

    private var preferredRegistration: Registration? {
        registrations.first { $0.window?.isKeyWindow == true }
            ?? registrations.first { $0.window?.isMainWindow == true }
            ?? registrations.max { $0.updatedAt < $1.updatedAt }
    }

    private func open(_ url: URL, in registration: Registration) {
        guard let browser = registration.browser else {
            pendingURLs.append(url)
            pruneRegistrations()
            return
        }

        browser.openExternalURL(url)
        registration.updatedAt = Date()

        if let window = registration.window {
            focus(window)
        }
    }

    private func drainPendingURLs(to registration: Registration) {
        guard !pendingURLs.isEmpty else {
            return
        }

        let urls = pendingURLs
        pendingURLs.removeAll()
        urls.forEach { open($0, in: registration) }
    }

    private func openBrowserCallbackURL(_ url: URL) {
        guard let session else {
            pendingCallbackURLs.append(url)
            return
        }

        session.handleGoogleOAuthCallback(url)
        focusExistingWindow()
    }

    private func drainPendingCallbackURLs() {
        guard !pendingCallbackURLs.isEmpty, session != nil else {
            return
        }

        let urls = pendingCallbackURLs
        pendingCallbackURLs.removeAll()
        urls.forEach(openBrowserCallbackURL)
    }

    private func pruneRegistrations() {
        registrations.removeAll { $0.browser == nil || $0.window == nil }
        if primaryWindow == nil {
            primaryWindow = preferredRegistration?.window
        }
    }

    private func focus(_ window: NSWindow?) {
        guard let window else {
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func closeDuplicate(_ window: NSWindow) {
        DispatchQueue.main.async { [weak window] in
            window?.close()
        }
    }
}
