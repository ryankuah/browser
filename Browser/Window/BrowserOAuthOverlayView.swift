import AppKit
import SwiftUI
import WebKit

struct BrowserOAuthOverlayView: View {
    let url: URL
    let onCallback: (URL) -> Void
    let onCancel: () -> Void
    let onOpenExternally: (URL) -> Void

    @State private var loadError: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                Divider()
                    .opacity(0.5)

                ZStack(alignment: .bottom) {
                    BrowserOAuthWebView(
                        url: url,
                        onCallback: onCallback,
                        onError: { loadError = $0.localizedDescription }
                    )

                    if let loadError {
                        fallbackBar(message: loadError)
                    }
                }
            }
            .frame(minWidth: 720, idealWidth: 940, maxWidth: 1080, minHeight: 560, idealHeight: 700, maxHeight: 820)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.28), radius: 28, x: 0, y: 18)
            .padding(28)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .font(.system(size: 14, weight: .semibold))

            Text("Connect Google")
                .font(.system(size: 14, weight: .semibold))

            Spacer()

            Button {
                onOpenExternally(url)
            } label: {
                Label("Open in Browser", systemImage: "safari")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.bordered)

            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Cancel")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func fallbackBar(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(message)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                onOpenExternally(url)
            } label: {
                Text("Continue in Browser")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }
}

private struct BrowserOAuthWebView: NSViewRepresentable {
    let url: URL
    let onCallback: (URL) -> Void
    let onError: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCallback: onCallback, onError: onError)
    }

    func makeNSView(context: Context) -> BrowserWebView {
        let webView = BrowserWebView(frame: .zero, configuration: BrowserWebView.makeConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .white
        webView.load(URLRequest(url: url))
        context.coordinator.loadedURL = url
        return webView
    }

    func updateNSView(_ webView: BrowserWebView, context: Context) {
        guard context.coordinator.loadedURL != url else {
            return
        }

        context.coordinator.loadedURL = url
        webView.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL: URL?

        private let onCallback: (URL) -> Void
        private let onError: (Error) -> Void

        init(onCallback: @escaping (URL) -> Void, onError: @escaping (Error) -> Void) {
            self.onCallback = onCallback
            self.onError = onError
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            if BrowserNavigation.isBrowserCallbackURL(url) {
                onCallback(url)
                decisionHandler(.cancel)
                return
            }

            if BrowserNavigation.isAllowedNavigationURL(url) {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleFailure(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handleFailure(error)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url,
                  BrowserNavigation.isGoogleOAuthCallbackURL(url) else {
                return
            }

            webView.evaluateJavaScript("document.body.innerText") { [weak self] result, _ in
                Task { @MainActor in
                    let bodyText = (result as? String) ?? ""
                    let callbackURL = Self.browserCallbackURL(fromCallbackPageText: bodyText)
                    self?.onCallback(callbackURL)
                }
            }
        }

        private func handleFailure(_ error: Error) {
            if let callbackURL = Self.browserCallbackURL(from: error) {
                onCallback(callbackURL)
                return
            }

            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                return
            }

            onError(error)
        }

        private static func browserCallbackURL(from error: Error) -> URL? {
            let nsError = error as NSError
            let candidate = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
                ?? (nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))

            guard let candidate, BrowserNavigation.isBrowserCallbackURL(candidate) else {
                return nil
            }

            return candidate
        }

        private static func browserCallbackURL(fromCallbackPageText text: String) -> URL {
            var components = URLComponents()
            components.scheme = BrowserNavigation.browserCallbackScheme
            components.host = "google"
            components.path = "/oauth/callback"

            if text.localizedCaseInsensitiveContains("failed") {
                components.queryItems = [
                    URLQueryItem(name: "status", value: "error"),
                    URLQueryItem(name: "message", value: text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Google OAuth failed.")
                ]
            } else {
                components.queryItems = [
                    URLQueryItem(name: "status", value: "success")
                ]
            }

            return components.url ?? URL(string: "\(BrowserNavigation.browserCallbackScheme)://google/oauth/callback?status=success")!
        }
    }
}
