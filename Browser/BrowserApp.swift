import SwiftUI

@main
struct BrowserApp: App {
    var body: some Scene {
        WindowGroup {
            BrowserWindowView()
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            BrowserCommands()
        }
    }
}

private struct BrowserCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") {
                NotificationCenter.default.post(name: .browserNewTabRequested, object: nil)
            }
            .keyboardShortcut("t", modifiers: [.command])

            Button("Close Tab") {
                NotificationCenter.default.post(name: .browserCloseTabRequested, object: nil)
            }
            .keyboardShortcut("w", modifiers: [.command])

            Button("Copy Page Link") {
                NotificationCenter.default.post(name: .browserCopyPageLinkRequested, object: nil)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Button("Reload Page") {
                NotificationCenter.default.post(name: .browserReloadRequested, object: nil)
            }
            .keyboardShortcut("r", modifiers: [.command])
        }

        CommandGroup(after: .appInfo) {
            Button("Show Console") {
                NotificationCenter.default.post(name: .browserConsoleRequested, object: nil)
            }
            .keyboardShortcut("j", modifiers: [.command, .option])
        }
    }
}

extension Notification.Name {
    static let browserNewTabRequested = Notification.Name("browserNewTabRequested")
    static let browserCloseTabRequested = Notification.Name("browserCloseTabRequested")
    static let browserCopyPageLinkRequested = Notification.Name("browserCopyPageLinkRequested")
    static let browserReloadRequested = Notification.Name("browserReloadRequested")
    static let browserConsoleRequested = Notification.Name("browserConsoleRequested")
}
