import SwiftUI
import WebKit

struct WebView: NSViewRepresentable {
    let url: URL
    let acceptsMouseEvents: Bool
    let cornerRadius: CGFloat

    init(url: URL, acceptsMouseEvents: Bool = true, cornerRadius: CGFloat = 0) {
        self.url = url
        self.acceptsMouseEvents = acceptsMouseEvents
        self.cornerRadius = cornerRadius
    }

    func makeNSView(context: Context) -> BrowserWebContainerView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(Self.mouseEventGateScript)

        let containerView = BrowserWebContainerView(configuration: configuration)
        containerView.cornerRadius = cornerRadius
        containerView.acceptsMouseEvents = acceptsMouseEvents
        containerView.setPageMouseEventsEnabled(acceptsMouseEvents)
        containerView.load(url)
        return containerView
    }

    func updateNSView(_ nsView: BrowserWebContainerView, context: Context) {
        nsView.cornerRadius = cornerRadius
        nsView.acceptsMouseEvents = acceptsMouseEvents
        nsView.setPageMouseEventsEnabled(acceptsMouseEvents)
    }

    private static let mouseEventGateScript = WKUserScript(
        source: """
        (() => {
            if (window.__browserMouseEventGateInstalled) {
                return;
            }

            window.__browserMouseEventGateInstalled = true;
            window.__browserMouseEventsEnabled = true;

            const blockedEvents = [
                "mousemove",
                "mouseover",
                "mouseenter",
                "mouseout",
                "mouseleave",
                "pointermove",
                "pointerover",
                "pointerenter",
                "pointerout",
                "pointerleave",
                "mousedown",
                "mouseup",
                "click",
                "dblclick",
                "contextmenu",
                "wheel"
            ];

            const blockWhenDisabled = (event) => {
                if (window.__browserMouseEventsEnabled === false) {
                    event.stopImmediatePropagation();

                    if (event.cancelable) {
                        event.preventDefault();
                    }
                }
            };

            for (const eventName of blockedEvents) {
                window.addEventListener(eventName, blockWhenDisabled, {
                    capture: true,
                    passive: false
                });
            }
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )
}

final class BrowserWebContainerView: NSView {
    private let webView: BrowserWebView

    var acceptsMouseEvents = true {
        didSet {
            webView.acceptsMouseEvents = acceptsMouseEvents
        }
    }

    var cornerRadius: CGFloat = 0 {
        didSet {
            layer?.cornerRadius = cornerRadius
        }
    }

    init(configuration: WKWebViewConfiguration) {
        webView = BrowserWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous

        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func setPageMouseEventsEnabled(_ isEnabled: Bool) {
        webView.setPageMouseEventsEnabled(isEnabled)
    }
}

final class BrowserWebView: WKWebView {
    var acceptsMouseEvents = true

    override func hitTest(_ point: NSPoint) -> NSView? {
        acceptsMouseEvents ? super.hitTest(point) : nil
    }

    func setPageMouseEventsEnabled(_ isEnabled: Bool) {
        evaluateJavaScript("window.__browserMouseEventsEnabled = \(isEnabled ? "true" : "false");")
    }
}
