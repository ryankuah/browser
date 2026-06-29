import SwiftUI
import WebKit

struct WebView: NSViewRepresentable {
    let webView: BrowserWebView?
    let cornerRadius: CGFloat
    let occlusionRects: [CGRect]
    let onMount: (() -> Void)?

    init(
        webView: BrowserWebView?,
        cornerRadius: CGFloat = 0,
        occlusionRects: [CGRect] = [],
        onMount: (() -> Void)? = nil
    ) {
        self.webView = webView
        self.cornerRadius = cornerRadius
        self.occlusionRects = occlusionRects
        self.onMount = onMount
    }

    func makeNSView(context: Context) -> BrowserWebContainerView {
        let containerView = BrowserWebContainerView()
        containerView.cornerRadius = cornerRadius
        containerView.occlusionRects = occlusionRects
        containerView.onWebViewMounted = onMount
        containerView.setWebView(webView)
        return containerView
    }

    func updateNSView(_ nsView: BrowserWebContainerView, context: Context) {
        nsView.cornerRadius = cornerRadius
        nsView.occlusionRects = occlusionRects
        nsView.onWebViewMounted = onMount
        nsView.setWebView(webView)
    }
}

final class BrowserWebContainerView: NSView {
    private var hostedWebView: BrowserWebView?
    private var hostedWebViewConstraints: [NSLayoutConstraint] = []
    private var isMountNotificationPending = false

    var onWebViewMounted: (() -> Void)?
    var occlusionRects: [CGRect] = [] {
        didSet {
            hostedWebView?.occlusionRects = occlusionRects
            window?.invalidateCursorRects(for: self)
            hostedWebView.map { window?.invalidateCursorRects(for: $0) }
        }
    }

    var cornerRadius: CGFloat = 0 {
        didSet {
            updateCornerMask()
        }
    }

    init() {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.clear.cgColor
        updateCornerMask()
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
        webView.occlusionRects = occlusionRects
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
        if isPointOccluded(point) {
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

    private func updateCornerMask() {
        let resolvedCornerRadius = max(cornerRadius, 0)
        layer?.cornerRadius = resolvedCornerRadius
        layer?.masksToBounds = resolvedCornerRadius > 0
    }

    private func isPointOccluded(_ point: NSPoint) -> Bool {
        occlusionRects.contains { $0.contains(point) }
    }
}

final class BrowserWebView: WKWebView {
    private static let defaultInitialFrame = CGRect(x: 0, y: 0, width: 1280, height: 800)
    static let desktopSafariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    static let safariUserAgentSuffix = "Version/18.0 Safari/605.1.15"
    private var isPointerShieldUpdatePending = false
    private var isElementFullscreenPresentationActive = false

    var occlusionRects: [CGRect] = [] {
        didSet {
            window?.invalidateCursorRects(for: self)
            updatePointerShield()
        }
    }

    func updateElementFullscreenPresentation(for fullscreenState: WKWebView.FullscreenState) {
        let isActive = fullscreenState == .enteringFullscreen
            || fullscreenState == .inFullscreen
            || fullscreenState == .exitingFullscreen
        guard isElementFullscreenPresentationActive != isActive else {
            return
        }

        isElementFullscreenPresentationActive = isActive
        underPageBackgroundColor = isActive ? .black : .clear
        setValue(isActive, forKey: "drawsBackground")

        if isActive {
            occlusionRects = []
        }

        needsDisplay = true
        layer?.setNeedsDisplay()
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
        if isPointOccluded(point) {
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
        if isEventInOccludedRegion(event) {
            updatePointerShield()
            return
        }

        super.mouseMoved(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        if isEventInOccludedRegion(event) {
            return
        }

        super.mouseEntered(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        if isEventInOccludedRegion(event) {
            updatePointerShield()
            return
        }

        super.cursorUpdate(with: event)
    }

    static func makeConfiguration(userScripts: [BrowserUserScript] = []) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configure(configuration, userScripts: userScripts)
        return configuration
    }

    static func configure(
        _ configuration: WKWebViewConfiguration,
        consoleMessageHandler: WKScriptMessageHandler? = nil,
        userScripts: [BrowserUserScript] = []
    ) {
        configuration.applicationNameForUserAgent = Self.safariUserAgentSuffix
        configuration.preferences.isElementFullscreenEnabled = true

        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences

        let userContentController = configuration.userContentController
        if let consoleMessageHandler {
            userContentController.add(consoleMessageHandler, name: "browserConsole")
        }
        installConfiguredUserScripts(
            on: userContentController,
            includeConsoleBridge: consoleMessageHandler != nil,
            userScripts: userScripts
        )
    }

    static func replaceConfiguredUserScripts(
        on userContentController: WKUserContentController,
        includeConsoleBridge: Bool,
        userScripts: [BrowserUserScript]
    ) {
        userContentController.removeAllUserScripts()
        installConfiguredUserScripts(
            on: userContentController,
            includeConsoleBridge: includeConsoleBridge,
            userScripts: userScripts
        )
    }

    private func isEventInOccludedRegion(_ event: NSEvent) -> Bool {
        isPointOccluded(convert(event.locationInWindow, from: nil))
    }

    private func isPointOccluded(_ point: NSPoint) -> Bool {
        bounds.contains(point) && occlusionRects.contains { $0.contains(point) }
    }

    private func shouldHandleAsWebContentKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              window?.firstResponder === self,
              let characters = event.charactersIgnoringModifiers,
              !characters.isEmpty else {
            return false
        }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        guard modifiers.isEmpty else {
            return false
        }

        return !Self.containsAppKitFunctionKey(characters)
    }

    private static func containsAppKitFunctionKey(_ characters: String) -> Bool {
        characters.unicodeScalars.contains { scalar in
            scalar.value >= 0xF700 && scalar.value <= 0xF8FF
        }
    }

    private func updatePointerShield() {
        guard !isPointerShieldUpdatePending else {
            return
        }

        isPointerShieldUpdatePending = true

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            self.isPointerShieldUpdatePending = false
            let rects = self.normalizedOcclusionRects()
            self.evaluateJavaScript(Self.pointerShieldScript(rects: rects), completionHandler: nil)
        }
    }

    private func normalizedOcclusionRects() -> [CGRect] {
        occlusionRects.compactMap { rect in
            let intersection = rect.intersection(bounds)
            guard !intersection.isNull,
                  intersection.width > 0,
                  intersection.height > 0 else {
                return nil
            }

            return intersection
        }
    }

    private static func pointerShieldScript(rects: [CGRect]) -> String {
        let rectJSON = rects.map { rect in
            """
            {"left":\(String(format: "%.2f", rect.minX)),"top":\(String(format: "%.2f", rect.minY)),"width":\(String(format: "%.2f", rect.width)),"height":\(String(format: "%.2f", rect.height))}
            """
        }
            .joined(separator: ",")

        return #"""
        (() => {
          const rootId = "__browserPointerShields";
          const rects = [RECTS];
          let root = document.getElementById(rootId);

          if (!root) {
            root = document.createElement("div");
            root.id = rootId;
            root.setAttribute("aria-hidden", "true");
            Object.assign(root.style, {
              position: "fixed",
              left: "0",
              top: "0",
              width: "0",
              height: "0",
              zIndex: "2147483647",
              pointerEvents: "none"
            });
            (document.documentElement || document.body).appendChild(root);
          }

          if (rects.length === 0) {
            root.remove();
            return;
          }

          while (root.children.length > rects.length) {
            root.lastChild.remove();
          }

          const block = event => {
            event.preventDefault();
            event.stopPropagation();
          };
          const stop = event => event.stopPropagation();
          const eventNames = ["click", "dblclick", "mousedown", "mouseup", "mousemove", "mouseover", "mouseout", "pointerdown", "pointerup", "pointermove", "pointerover", "pointerout"];

          rects.forEach((rect, index) => {
            let shield = root.children[index];
            if (!shield) {
              shield = document.createElement("div");
              shield.addEventListener("contextmenu", block, true);
              for (const name of eventNames) {
                shield.addEventListener(name, stop, true);
              }
              root.appendChild(shield);
            }

            Object.assign(shield.style, {
              position: "fixed",
              left: `${rect.left}px`,
              top: `${rect.top}px`,
              width: `${rect.width}px`,
              height: `${rect.height}px`,
              zIndex: "2147483647",
              background: "transparent",
              cursor: "auto",
              pointerEvents: "auto"
            });
          });
        })();
        """#
            .replacingOccurrences(of: "RECTS", with: rectJSON)
    }

    private static func installConfiguredUserScripts(
        on userContentController: WKUserContentController,
        includeConsoleBridge: Bool,
        userScripts: [BrowserUserScript]
    ) {
        if includeConsoleBridge {
            userContentController.addUserScript(WKUserScript(
                source: consoleBridgeScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
        }

        for userScript in userScripts where userScript.isRunnable {
            userContentController.addUserScript(WKUserScript(
                source: wrappedUserScriptSource(for: userScript),
                injectionTime: webKitInjectionTime(for: userScript.injectionTime),
                forMainFrameOnly: userScript.forMainFrameOnly
            ))
        }
    }

    private static func webKitInjectionTime(for injectionTime: BrowserUserScriptInjectionTime) -> WKUserScriptInjectionTime {
        switch injectionTime {
        case .documentStart:
            return .atDocumentStart
        case .documentEnd:
            return .atDocumentEnd
        }
    }

    private static func wrappedUserScriptSource(for userScript: BrowserUserScript) -> String {
        #"""
        (() => {
          const scriptName = __BROWSER_USER_SCRIPT_NAME__;
          const patterns = __BROWSER_USER_SCRIPT_PATTERNS__;
          const escapeRegExp = value => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
          const wildcardToRegExp = value => new RegExp(`^${String(value).split("*").map(escapeRegExp).join(".*")}$`);
          const matchesHost = (pattern, host) => {
            const normalizedPattern = String(pattern || "*").toLowerCase();
            const normalizedHost = String(host || "").toLowerCase();
            if (normalizedPattern === "*" || normalizedPattern === "") return true;
            if (normalizedPattern.startsWith("*.")) {
              const base = normalizedPattern.slice(2);
              return normalizedHost === base || normalizedHost.endsWith(`.${base}`);
            }
            return wildcardToRegExp(normalizedPattern).test(normalizedHost);
          };
          const matchesPattern = pattern => {
            const normalizedPattern = String(pattern || "").trim();
            if (!normalizedPattern || normalizedPattern === "*" || normalizedPattern === "<all_urls>") return true;

            const url = new URL(location.href);
            const match = normalizedPattern.match(/^(\*|https?|file):\/\/([^/]*)(\/.*)?$/i);
            if (!match) {
              if (!normalizedPattern.includes("/") && !normalizedPattern.includes(":")) {
                return matchesHost(normalizedPattern, url.hostname);
              }
              return wildcardToRegExp(normalizedPattern).test(location.href);
            }

            const expectedScheme = match[1].toLowerCase();
            const actualScheme = url.protocol.replace(/:$/, "").toLowerCase();
            if (expectedScheme !== "*" && expectedScheme !== actualScheme) return false;

            const hostPattern = match[2] || "*";
            if (actualScheme !== "file" && !matchesHost(hostPattern, url.hostname)) return false;

            const pathPattern = match[3] || "/*";
            return wildcardToRegExp(pathPattern).test(`${url.pathname}${url.search}${url.hash}`);
          };

          if (!patterns.some(matchesPattern)) return;

          try {
        __BROWSER_USER_SCRIPT_SOURCE__
          } catch (error) {
            console.error(`[Browser user script: ${scriptName}]`, error);
          }
        })();
        """#
        .replacingOccurrences(of: "__BROWSER_USER_SCRIPT_NAME__", with: javascriptStringLiteral(userScript.displayName))
        .replacingOccurrences(of: "__BROWSER_USER_SCRIPT_PATTERNS__", with: javascriptArrayLiteral(userScript.normalizedMatchPatternLines))
        .replacingOccurrences(of: "__BROWSER_USER_SCRIPT_SOURCE__", with: indentedUserScriptSource(userScript.source))
    }

    private static func javascriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }

        return literal
    }

    private static func javascriptArrayLiteral(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let literal = String(data: data, encoding: .utf8) else {
            return "[]"
        }

        return literal
    }

    private static func indentedUserScriptSource(_ source: String) -> String {
        source
            .components(separatedBy: .newlines)
            .map { "            \($0)" }
            .joined(separator: "\n")
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
