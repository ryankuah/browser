import SwiftUI

@main
struct BrowserApp: App {
    private let initialURL = URL(string: "https://ryankuah.com")!

    var body: some Scene {
        WindowGroup {
            BrowserWindowView(url: initialURL)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
