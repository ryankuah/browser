import SwiftUI
import WebKit

struct WebView: NSViewRepresentable {
    let webView: BrowserWebView?
    let cornerRadius: CGFloat
    let blockedHitTestWidth: CGFloat
    let onMount: (() -> Void)?

    init(
        webView: BrowserWebView?,
        cornerRadius: CGFloat = 0,
        blockedHitTestWidth: CGFloat = 0,
        onMount: (() -> Void)? = nil
    ) {
        self.webView = webView
        self.cornerRadius = cornerRadius
        self.blockedHitTestWidth = blockedHitTestWidth
        self.onMount = onMount
    }

    func makeNSView(context: Context) -> BrowserWebContainerView {
        let containerView = BrowserWebContainerView()
        containerView.cornerRadius = cornerRadius
        containerView.blockedHitTestWidth = blockedHitTestWidth
        containerView.onWebViewMounted = onMount
        containerView.setWebView(webView)
        return containerView
    }

    func updateNSView(_ nsView: BrowserWebContainerView, context: Context) {
        nsView.cornerRadius = cornerRadius
        nsView.blockedHitTestWidth = blockedHitTestWidth
        nsView.onWebViewMounted = onMount
        nsView.setWebView(webView)
    }
}

final class BrowserWebContainerView: NSView {
    private var hostedWebView: BrowserWebView?
    private var hostedWebViewConstraints: [NSLayoutConstraint] = []
    private var isMountNotificationPending = false

    var onWebViewMounted: (() -> Void)?
    var blockedHitTestWidth: CGFloat = 0 {
        didSet {
            hostedWebView?.blockedHitTestWidth = blockedHitTestWidth
            window?.invalidateCursorRects(for: self)
            hostedWebView.map { window?.invalidateCursorRects(for: $0) }
        }
    }

    var cornerRadius: CGFloat = 0 {
        didSet {
            layer?.cornerRadius = cornerRadius
        }
    }

    init() {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func setWebView(_ webView: BrowserWebView?) {
        guard hostedWebView !== webView else {
            return
        }

        NSLayoutConstraint.deactivate(hostedWebViewConstraints)
        hostedWebViewConstraints = []
        hostedWebView?.removeFromSuperview()
        hostedWebView = webView
        isMountNotificationPending = false

        guard let webView else {
            return
        }

        webView.removeFromSuperview()
        webView.blockedHitTestWidth = blockedHitTestWidth
        if bounds.width > 1, bounds.height > 1 {
            webView.frame = bounds
        }
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)

        hostedWebViewConstraints = [
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ]
        NSLayoutConstraint.activate(hostedWebViewConstraints)

        DispatchQueue.main.async { [weak self] in
            self?.isMountNotificationPending = true
            self?.notifyMountedIfReady()
        }
    }

    override func layout() {
        super.layout()
        notifyMountedIfReady()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        notifyMountedIfReady()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if point.x >= 0, point.x < blockedHitTestWidth {
            return nil
        }

        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        focusHostedWebView()
        super.mouseDown(with: event)
    }

    private func notifyMountedIfReady() {
        guard isMountNotificationPending,
              let hostedWebView,
              window != nil else {
            return
        }

        layoutSubtreeIfNeeded()

        guard hostedWebView.bounds.width > 1,
              hostedWebView.bounds.height > 1 else {
            return
        }

        hostedWebView.frame = bounds
        hostedWebView.layoutSubtreeIfNeeded()
        focusHostedWebView()

        isMountNotificationPending = false
        onWebViewMounted?()
    }

    private func focusHostedWebView() {
        guard let hostedWebView,
              window?.firstResponder !== hostedWebView else {
            return
        }

        window?.makeFirstResponder(hostedWebView)
    }
}

final class BrowserWebView: WKWebView {
    private static let defaultInitialFrame = CGRect(x: 0, y: 0, width: 1280, height: 800)
    static let desktopSafariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    static let safariUserAgentSuffix = "Version/18.0 Safari/605.1.15"
    private var isPointerShieldUpdatePending = false

    var blockedHitTestWidth: CGFloat = 0 {
        didSet {
            window?.invalidateCursorRects(for: self)
            updatePointerShield()
        }
    }

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame == .zero ? Self.defaultInitialFrame : frame, configuration: configuration)
        allowsBackForwardNavigationGestures = true
        setValue(false, forKey: "drawsBackground")
        customUserAgent = Self.desktopSafariUserAgent
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if isPointInBlockedRegion(point) {
            return nil
        }

        return super.hitTest(point)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard shouldHandleAsWebContentKey(event) else {
            return super.performKeyEquivalent(with: event)
        }

        // WebKit calls back through AppKit when web content does not handle a key.
        // Consume plain keys here to prevent AppKit's system beep without
        // re-dispatching the event into WKWebView and recursively re-entering
        // this path.
        return true
    }

    override func mouseMoved(with event: NSEvent) {
        if isEventInBlockedRegion(event) {
            updatePointerShield()
            return
        }

        super.mouseMoved(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        if isEventInBlockedRegion(event) {
            return
        }

        super.mouseEntered(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        if isEventInBlockedRegion(event) {
            updatePointerShield()
            return
        }

        super.cursorUpdate(with: event)
    }

    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configure(configuration)
        return configuration
    }

    static func configure(_ configuration: WKWebViewConfiguration, consoleMessageHandler: WKScriptMessageHandler? = nil) {
        configuration.applicationNameForUserAgent = Self.safariUserAgentSuffix
        configuration.preferences.isElementFullscreenEnabled = true

        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences

        let userContentController = configuration.userContentController
        userContentController.addUserScript(WKUserScript(
            source: youtubePlaybackSpeedHotkeyScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        guard let consoleMessageHandler else {
            return
        }

        userContentController.add(consoleMessageHandler, name: "browserConsole")
        userContentController.addUserScript(WKUserScript(
            source: consoleBridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
    }

    private func isEventInBlockedRegion(_ event: NSEvent) -> Bool {
        isPointInBlockedRegion(convert(event.locationInWindow, from: nil))
    }

    private func isPointInBlockedRegion(_ point: NSPoint) -> Bool {
        blockedHitTestWidth > 0
            && point.x >= 0
            && point.x < blockedHitTestWidth
            && bounds.contains(point)
    }

    private func shouldHandleAsWebContentKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              window?.firstResponder === self,
              !(event.charactersIgnoringModifiers?.isEmpty ?? true) else {
            return false
        }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        return modifiers.isEmpty
    }

    private func updatePointerShield() {
        guard !isPointerShieldUpdatePending else {
            return
        }

        isPointerShieldUpdatePending = true
        let width = max(blockedHitTestWidth, 0)

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            self.isPointerShieldUpdatePending = false
            self.evaluateJavaScript(Self.pointerShieldScript(width: width), completionHandler: nil)
        }
    }

    private static func pointerShieldScript(width: CGFloat) -> String {
        let width = max(width, 0)

        return #"""
        (() => {
          const id = "__browserSidebarPointerShield";
          let shield = document.getElementById(id);

          if (!shield) {
            shield = document.createElement("div");
            shield.id = id;
            shield.setAttribute("aria-hidden", "true");
            shield.addEventListener("contextmenu", event => event.preventDefault(), true);
            for (const name of ["click", "dblclick", "mousedown", "mouseup", "mousemove", "mouseover", "mouseout", "pointerdown", "pointerup", "pointermove", "pointerover", "pointerout"]) {
              shield.addEventListener(name, event => event.stopPropagation(), true);
            }
            (document.documentElement || document.body).appendChild(shield);
          }

          if (WIDTH <= 0) {
            shield.remove();
            return;
          }

          Object.assign(shield.style, {
            position: "fixed",
            left: "0",
            top: "0",
            width: `${WIDTH}px`,
            height: "100vh",
            zIndex: "2147483647",
            background: "transparent",
            cursor: "auto",
            pointerEvents: "auto"
          });
        })();
        """#
            .replacingOccurrences(of: "WIDTH", with: String(format: "%.2f", width))
    }

    private static let consoleBridgeScript = #"""
    (() => {
      if (window.__browserConsoleBridgeInstalled) return;
      window.__browserConsoleBridgeInstalled = true;

      const post = (level, values, source = "page") => {
        try {
          window.webkit.messageHandlers.browserConsole.postMessage({
            level,
            source,
            url: String(location.href),
            message: values.map(value => {
              try {
                if (typeof value === "string") return value;
                if (value instanceof Error) return `${value.name}: ${value.message}\n${value.stack || ""}`;
                if (value instanceof Element) return value.outerHTML;
                if (typeof value === "undefined") return "undefined";
                return JSON.stringify(value);
              } catch (_) {
                return String(value);
              }
            }).join(" ")
          });
        } catch (_) {}
      };

      for (const level of ["debug", "log", "info", "warn", "error"]) {
        const original = console[level];
        console[level] = function(...values) {
          post(level, values);
          return original.apply(this, values);
        };
      }

      const diagnostics = (phase) => {
        const connection = navigator.connection || navigator.webkitConnection || navigator.mozConnection;
        let localStorageAvailable = false;
        try {
          localStorageAvailable = !!window.localStorage;
        } catch (_) {}

        post("debug", [{
          phase,
          userAgent: navigator.userAgent,
          cookieEnabled: navigator.cookieEnabled,
          webdriver: navigator.webdriver,
          saveData: connection ? connection.saveData : null,
          effectiveType: connection ? connection.effectiveType : null,
          hardwareConcurrency: navigator.hardwareConcurrency,
          language: navigator.language,
          languages: navigator.languages,
          localStorageAvailable,
          url: location.href
        }], "diagnostic");
      };

      diagnostics("document-start");
      window.addEventListener("DOMContentLoaded", () => diagnostics("dom-content-loaded"), { once: true });
      window.addEventListener("load", () => diagnostics("window-load"), { once: true });
    })();
    """#

    private static let youtubePlaybackSpeedHotkeyScript = #"""
    (() => {
      if (window.__browserYouTubePlaybackSpeedHotkeysInstalled) return;
      window.__browserYouTubePlaybackSpeedHotkeysInstalled = true;

      const isYouTubePage = () => {
        const host = location.hostname.toLowerCase();
        return host === "youtube.com" || host.endsWith(".youtube.com");
      };

      const isEditableTarget = target => {
        if (!target || target === document || target === window) return false;
        const element = target.nodeType === Node.ELEMENT_NODE ? target : target.parentElement;
        return Boolean(element?.closest([
          "input",
          "textarea",
          "select",
          "[contenteditable]",
          "[role='textbox']"
        ].join(",")));
      };

      const clampPlaybackSpeed = speed => Math.min(16, Math.max(0.25, speed));

      const formatPlaybackSpeed = speed => {
        const rounded = Math.round(speed * 100) / 100;
        return Number.isInteger(rounded) ? `${rounded}x` : `${rounded.toFixed(2).replace(/0$/, "")}x`;
      };

      const getPreferredVideo = () => {
        const videos = Array.from(document.querySelectorAll("video"));
        return (
          videos.find(candidate => !candidate.paused && !candidate.ended) ||
          videos.find(candidate => candidate.readyState > 0) ||
          videos[0]
        );
      };

      const showPlaybackSpeedPopup = speed => {
        const video = getPreferredVideo();
        if (!video) return;

        let popup = document.getElementById("browser-youtube-playback-speed-popup");
        if (!popup) {
          popup = document.createElement("div");
          popup.id = "browser-youtube-playback-speed-popup";
          popup.setAttribute("aria-live", "polite");
          Object.assign(popup.style, {
            position: "fixed",
            zIndex: "2147483647",
            padding: "8px 14px",
            borderRadius: "999px",
            background: "rgba(8, 8, 10, 0.72)",
            border: "1px solid rgba(255, 255, 255, 0.18)",
            boxShadow: "0 10px 30px rgba(0, 0, 0, 0.35), inset 0 1px 0 rgba(255, 255, 255, 0.18)",
            backdropFilter: "blur(18px) saturate(160%)",
            WebkitBackdropFilter: "blur(18px) saturate(160%)",
            color: "white",
            font: "600 14px -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', sans-serif",
            letterSpacing: "0",
            lineHeight: "1",
            pointerEvents: "none",
            opacity: "0",
            transform: "translate(-50%, -8px) scale(0.98)",
            transition: "opacity 140ms ease, transform 140ms ease"
          });
          document.documentElement.appendChild(popup);
        }

        const rect = video.getBoundingClientRect();
        popup.textContent = formatPlaybackSpeed(speed);
        popup.style.left = `${rect.left + rect.width / 2}px`;
        popup.style.top = `${Math.max(12, rect.top + 18)}px`;
        popup.style.opacity = "1";
        popup.style.transform = "translate(-50%, 0) scale(1)";

        clearTimeout(window.__browserYouTubePlaybackSpeedPopupTimer);
        window.__browserYouTubePlaybackSpeedPopupTimer = setTimeout(() => {
          popup.style.opacity = "0";
          popup.style.transform = "translate(-50%, -8px) scale(0.98)";
        }, 900);
      };

      const setPlaybackSpeed = speed => {
        const video = getPreferredVideo();

        if (!video) return;

        const nextSpeed = clampPlaybackSpeed(speed);
        video.defaultPlaybackRate = nextSpeed;
        video.playbackRate = nextSpeed;
        showPlaybackSpeedPopup(nextSpeed);
      };

      const adjustPlaybackSpeed = delta => {
        const video = getPreferredVideo();
        const currentSpeed = video?.playbackRate || 1;
        setPlaybackSpeed(currentSpeed + delta);
      };

      window.addEventListener("keydown", event => {
        if (!isYouTubePage()) return;
        if (event.defaultPrevented || event.repeat) return;
        if (event.metaKey || event.ctrlKey || event.altKey) return;
        if (isEditableTarget(event.target)) return;

        switch (event.key.toLowerCase()) {
        case "s":
          event.preventDefault();
          event.stopPropagation();
          adjustPlaybackSpeed(-0.25);
          break;
        case "d":
          event.preventDefault();
          event.stopPropagation();
          adjustPlaybackSpeed(0.25);
          break;
        case "g":
          event.preventDefault();
          event.stopPropagation();
          setPlaybackSpeed(3);
          break;
        case "h":
          event.preventDefault();
          event.stopPropagation();
          setPlaybackSpeed(1);
          break;
        default:
          break;
        }
      }, true);
    })();
    """#

}

final class BrowserConsoleScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var browser: BrowserState?

    init(browser: BrowserState) {
        self.browser = browser
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor [weak browser] in
            browser?.receiveConsoleMessage(message.body)
        }
    }
}
