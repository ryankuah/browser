import SwiftUI

enum BrowserWindowCoordinateSpace {
    static let root = "BrowserWindowRoot"
}

struct WebViewOcclusionPreferenceKey: PreferenceKey {
    static let defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    func webViewOcclusionRegion() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: WebViewOcclusionPreferenceKey.self,
                    value: [proxy.frame(in: .named(BrowserWindowCoordinateSpace.root))]
                )
            }
        }
    }
}
