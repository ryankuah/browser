import SwiftUI
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let updateController = BrowserUpdateController()
}

@MainActor
final class BrowserUpdateController: NSObject, ObservableObject, SPUUserDriver {
    enum UpdateState {
        case idle
        case checking
        case available
        case downloading
        case extracting
        case readyToInstall
        case installing
        case failed
    }

    @Published private(set) var state: UpdateState = .idle

    private var updater: SPUUpdater!
    private var updateChoiceReply: ((SPUUserUpdateChoice) -> Void)?
    private var readyToInstallReply: ((SPUUserUpdateChoice) -> Void)?
    private var expectedContentLength: UInt64 = 0
    private var receivedContentLength: UInt64 = 0

    var isUpdateButtonVisible: Bool {
        switch state {
        case .idle, .checking:
            return false
        case .available, .downloading, .extracting, .readyToInstall, .installing, .failed:
            return true
        }
    }

    var updateButtonIconSystemName: String {
        switch state {
        case .failed:
            return "exclamationmark.triangle.fill"
        case .downloading, .extracting, .installing:
            return "arrow.down.circle.fill"
        default:
            return "arrow.triangle.2.circlepath.circle.fill"
        }
    }

    var updateButtonHelp: String {
        switch state {
        case .available:
            return "Download Update"
        case .downloading:
            return "Downloading Update"
        case .extracting:
            return "Preparing Update"
        case .readyToInstall:
            return "Restart and Apply Update"
        case .installing:
            return "Installing Update"
        case .failed:
            return "Check for Updates"
        case .idle, .checking:
            return "Check for Updates"
        }
    }

    override init() {
        super.init()
        updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: self,
            delegate: nil
        )

        do {
            try updater.start()
        } catch {
            NSLog("Browser updater failed to start: \(error.localizedDescription)")
        }
    }

    func checkForUpdates() {
        guard updater.canCheckForUpdates else {
            return
        }

        updater.checkForUpdates()
    }

    func performUpdateButtonAction() {
        switch state {
        case .available:
            let reply = updateChoiceReply
            updateChoiceReply = nil
            state = .downloading
            reply?(.install)
        case .readyToInstall:
            let reply = readyToInstallReply
            readyToInstallReply = nil
            state = .installing
            reply?(.install)
        case .failed:
            state = .idle
            checkForUpdates()
        default:
            break
        }
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        state = .checking
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state updateState: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if appcastItem.isInformationOnlyUpdate {
            reply(.dismiss)
            self.state = .idle
            return
        }

        updateChoiceReply = reply
        self.state = updateState.stage == .downloaded ? .readyToInstall : .available
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        state = .idle
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        NSLog("Browser updater error: \(error.localizedDescription)")
        state = .failed
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        state = .downloading
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        self.expectedContentLength = expectedContentLength
        receivedContentLength = 0
        state = .downloading
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedContentLength += length
        state = .downloading
    }

    func showDownloadDidStartExtractingUpdate() {
        state = .extracting
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        state = .extracting
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        readyToInstallReply = reply
        state = .readyToInstall
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        state = .installing
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        state = .idle
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        updateChoiceReply = nil
        readyToInstallReply = nil
        state = .idle
    }

    func showUpdateInFocus() {}
}

@main
struct BrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            BrowserWindowView(updateController: appDelegate.updateController)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            BrowserCommands(updateController: appDelegate.updateController)
        }
    }
}

private struct BrowserCommands: Commands {
    @FocusedValue(\.browserCommandActions) private var browserCommandActions
    let updateController: BrowserUpdateController

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
                updateController.checkForUpdates()
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
