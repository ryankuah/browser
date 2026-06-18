import SwiftUI
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
}

@main
struct BrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            BrowserWindowView()
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            BrowserCommands(updater: appDelegate.updaterController.updater)
        }
    }
}

private struct BrowserCommands: Commands {
    @FocusedValue(\.browserCommandActions) private var browserCommandActions
    let updater: SPUUpdater

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") {
                browserCommandActions?.newTab()
            }
            .keyboardShortcut("t", modifiers: [.command])
            .disabled(browserCommandActions == nil)

            Button("Close Tab") {
                browserCommandActions?.closeTab()
            }
            .keyboardShortcut("w", modifiers: [.command])
            .disabled(browserCommandActions == nil)

            Button("Copy Page Link") {
                browserCommandActions?.copyPageLink()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(browserCommandActions == nil)

            Button("Reload Page") {
                browserCommandActions?.reload()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(browserCommandActions == nil)
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates...") {
                updater.checkForUpdates()
            }

            Button("Show Console") {
                browserCommandActions?.toggleConsole()
            }
            .keyboardShortcut("j", modifiers: [.command, .option])
            .disabled(browserCommandActions == nil)
        }
    }
}

struct BrowserCommandActions {
    var newTab: () -> Void
    var closeTab: () -> Void
    var copyPageLink: () -> Void
    var reload: () -> Void
    var toggleConsole: () -> Void
}

private struct BrowserCommandActionsKey: FocusedValueKey {
    typealias Value = BrowserCommandActions
}

extension FocusedValues {
    var browserCommandActions: BrowserCommandActions? {
        get { self[BrowserCommandActionsKey.self] }
        set { self[BrowserCommandActionsKey.self] = newValue }
    }
}
