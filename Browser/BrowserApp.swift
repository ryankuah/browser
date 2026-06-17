import SwiftUI

@main
struct BrowserApp: App {
    var body: some Scene {
        WindowGroup {
            BrowserWindowView()
        }
        .windowStyle(.hiddenTitleBar)
    }
}
