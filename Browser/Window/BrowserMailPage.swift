import AppKit
import SwiftUI
import WebKit

struct BrowserMailPage: View {
    @ObservedObject var browser: BrowserState
    @ObservedObject var session: BrowserSessionController
    let onClose: () -> Void

    @State private var selectedThreadID: BrowserMailThread.ID?
    @State private var selectedCategory: GmailCategory?
    @State private var query = ""

    private var threads: [BrowserMailThread] {
        BrowserMailThread.grouping(session.mailMessages)
    }

    private var filteredThreads: [BrowserMailThread] {
        let categoryThreads: [BrowserMailThread]
        if let selectedCategory {
            categoryThreads = threads.filter { thread in
                thread.messages.contains { message in
                    message.labelIds.contains(selectedCategory.labelID)
                }
            }
        } else {
            categoryThreads = threads
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            return categoryThreads
        }

        return categoryThreads.filter { thread in
            thread.messages.contains { message in
                [message.from, message.to, message.subject, message.snippet]
                    .compactMap { $0?.lowercased() }
                    .contains { $0.contains(trimmed) }
            }
        }
    }

    private var selectedThread: BrowserMailThread? {
        if let selectedThreadID,
           let thread = filteredThreads.first(where: { $0.id == selectedThreadID }) {
            return thread
        }

        return filteredThreads.first
    }

    private var gmailCategorySummaries: [GmailCategorySummary] {
        GmailCategory.allCases.compactMap { category in
            let count = session.mailMessages.filter { $0.labelIds.contains(category.labelID) }.count
            guard count > 0 else {
                return nil
            }

            return GmailCategorySummary(category: category, count: count)
        }
    }

    var body: some View {
        ZStack {
            BrowserChromeBackground(
                bezelStyle: browser.bezelStyle,
                cornerRadius: 0,
                effect: .liquidGlass(style: .regular, tintColor: NSColor.black.withAlphaComponent(0.16)),
                profileColor: browser.profileNSColor
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                Divider()
                    .opacity(0.45)

                if session.mailMessages.isEmpty {
                    emptyState
                } else {
                    mailContent
                }
            }
        }
        .onAppear {
            session.refreshCloudData()
            if selectedThreadID == nil {
                selectedThreadID = filteredThreads.first?.id
            }
        }
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Mail")

            Image(systemName: "envelope")
                .font(.system(size: 15, weight: .semibold))

            Text("Mail")
                .font(.system(size: 15, weight: .semibold))

            Text("\(session.mailMessages.count)")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            if !gmailCategorySummaries.isEmpty {
                HStack(spacing: 4) {
                    MailCategoryFilterButton(
                        title: "All",
                        count: session.mailMessages.count,
                        isSelected: selectedCategory == nil
                    ) {
                        selectedCategory = nil
                        selectedThreadID = nil
                    }

                    ForEach(gmailCategorySummaries) { summary in
                        MailCategoryFilterButton(
                            title: summary.category.title,
                            count: summary.count,
                            isSelected: selectedCategory == summary.category
                        ) {
                            selectedCategory = summary.category
                            selectedThreadID = nil
                        }
                    }
                }
                .lineLimit(1)
                .layoutPriority(1)
                .frame(maxWidth: 430, alignment: .leading)
                .clipped()
            }

            Spacer()

            TextField("Search mail", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .frame(width: 240, height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                }

            Button {
                session.refreshCloudData()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("No Imported Mail")
                .font(.system(size: 15, weight: .semibold))

            Text(emptyStateMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            if session.hasConnectedGoogleAccount {
                Button {
                    session.refreshCloudData()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    session.openGoogleConnectionURL()
                } label: {
                    Label("Connect Google", systemImage: "link")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateMessage: String {
        if let account = session.googleAccounts.first {
            return "Google is connected as \(account.email). Mail may still be importing, or Gmail returned no recent messages."
        }

        return "Connect Google to import Gmail messages and attachments into Convex. Google remains read-only."
    }

    private var mailContent: some View {
        HStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredThreads) { thread in
                        MailThreadRow(
                            thread: thread,
                            isSelected: selectedThread?.id == thread.id
                        ) {
                            selectedThreadID = thread.id
                        }
                        .onAppear {
                            if thread.id == filteredThreads.last?.id {
                                session.loadMoreMailMessages()
                            }
                        }
                    }

                    if session.isLoadingMoreMailMessages {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(width: 340)

            Divider()
                .opacity(0.45)

            if let selectedThread {
                MailThreadDetail(thread: selectedThread, session: session)
            } else {
                emptySearchState
            }
        }
    }

    private var emptySearchState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("No Matches")
                .font(.system(size: 14, weight: .semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum GmailCategory: String, CaseIterable, Identifiable {
    case personal
    case social
    case promotions
    case updates
    case forums

    var id: String { labelID }

    var labelID: String {
        switch self {
        case .personal: return "CATEGORY_PERSONAL"
        case .social: return "CATEGORY_SOCIAL"
        case .promotions: return "CATEGORY_PROMOTIONS"
        case .updates: return "CATEGORY_UPDATES"
        case .forums: return "CATEGORY_FORUMS"
        }
    }

    var title: String {
        switch self {
        case .personal: return "Personal"
        case .social: return "Social"
        case .promotions: return "Promotions"
        case .updates: return "Updates"
        case .forums: return "Forums"
        }
    }
}

private struct GmailCategorySummary: Identifiable {
    let category: GmailCategory
    let count: Int

    var id: String { category.id }
}

private struct MailCategoryFilterButton: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .lineLimit(1)
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.14) : Color.primary.opacity(0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(isSelected ? Color.primary.opacity(0.22) : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .help("\(count) loaded messages in \(title)")
    }
}

private struct MailThreadRow: View {
    let thread: BrowserMailThread
    let isSelected: Bool
    let onSelect: () -> Void

    private var message: BrowserMailMessage {
        thread.latestMessage
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(message.displaySender)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)

                    if thread.messages.count > 1 {
                        Text("\(thread.messages.count)")
                            .font(.system(size: 10, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background {
                                Capsule().fill(Color.primary.opacity(0.08))
                            }
                    }

                    Spacer()

                    if let displayDate = message.displayDate {
                        Text(displayDate, style: .date)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(message.subject ?? "No subject")
                    .font(.system(size: 12))
                    .lineLimit(1)

                Text(message.snippet ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.primary.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct MailThreadDetail: View {
    let thread: BrowserMailThread
    @ObservedObject var session: BrowserSessionController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(thread.messages.enumerated()), id: \.element.id) { index, message in
                    mailMessageDetail(message)

                    if index < thread.messages.count - 1 {
                        Divider()
                            .opacity(0.45)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private func mailMessageDetail(_ message: BrowserMailMessage) -> some View {
        MailMessageDetail(
            message: message,
            messageBody: session.mailMessageBodies[message.providerMessageId],
            onLoadBody: {
                session.loadMailMessageBody(message)
            }
        )
    }
}

private struct MailMessageDetail: View {
    let message: BrowserMailMessage
    let messageBody: BrowserMailMessageBody?
    let onLoadBody: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(message.subject ?? "No subject")
                    .font(.system(size: 20, weight: .semibold))
                    .textSelection(.enabled)

                VStack(alignment: .leading, spacing: 4) {
                    headerLine("From", message.from)
                    headerLine("To", message.to)
                    if let date = message.displayDate {
                        headerLine("Date", DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short))
                    }
                }
                .font(.system(size: 12))
            }

            MailBodyView(
                html: messageBody?.bodyHtml ?? message.bodyHtml,
                text: messageBody?.bodyText ?? message.bodyText ?? message.snippet
            )
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear(perform: onLoadBody)
    }

    private func headerLine(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
            Text(value ?? "-")
                .textSelection(.enabled)
        }
    }
}

private struct MailBodyView: View {
    let html: String?
    let text: String?
    @State private var htmlHeight: CGFloat = 360

    var body: some View {
        if let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            MailHTMLWebView(html: html, contentHeight: $htmlHeight)
                .frame(maxWidth: .infinity)
                .frame(height: htmlHeight)
        } else {
            Text(text ?? "No body imported for this message.")
                .font(.system(size: 13))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MailHTMLWebView: NSViewRepresentable {
    let html: String
    @Binding var contentHeight: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "heightObserver")
        configuration.userContentController = userContentController
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = MailBodyWKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        webView.enclosingScrollView?.drawsBackground = false
        webView.enclosingScrollView?.hasVerticalScroller = false
        webView.enclosingScrollView?.autohidesScrollers = true
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else {
            return
        }

        context.coordinator.loadedHTML = html
        context.coordinator.contentHeight = $contentHeight
        contentHeight = 360
        webView.loadHTMLString(wrappedHTML, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight)
    }

    private var wrappedHTML: String {
        """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            html, body { margin: 0; padding: 0; background: transparent; color: CanvasText; overflow: hidden; }
            body { font: -apple-system-body; overflow-wrap: anywhere; }
            img, table { max-width: 100%; height: auto; }
            a { color: -apple-system-control-accent; }
          </style>
          <script>
            function postHeight() {
              const height = Math.max(
                document.body.scrollHeight,
                document.documentElement.scrollHeight,
                document.body.offsetHeight,
                document.documentElement.offsetHeight
              );
              window.webkit.messageHandlers.heightObserver.postMessage(height);
            }
            window.addEventListener('load', postHeight);
            window.addEventListener('resize', postHeight);
            new ResizeObserver(postHeight).observe(document.documentElement);
          </script>
        </head>
        <body>\(html)</body>
        </html>
        """
    }

    final class MailBodyWKWebView: WKWebView {
        override func scrollWheel(with event: NSEvent) {
            superview?.scrollWheel(with: event)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var contentHeight: Binding<CGFloat>
        var loadedHTML: String?

        init(contentHeight: Binding<CGFloat>) {
            self.contentHeight = contentHeight
        }

        @MainActor
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                BrowserExternalURLRouter.shared.openExternalURL(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        @MainActor
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            updateHeight(from: webView)
        }

        @MainActor
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let height = message.body as? Double {
                setHeight(CGFloat(height))
            } else if let height = message.body as? CGFloat {
                setHeight(height)
            } else if let height = message.body as? Int {
                setHeight(CGFloat(height))
            }
        }

        @MainActor
        private func updateHeight(from webView: WKWebView) {
            let script = """
            Math.max(
              document.body.scrollHeight,
              document.documentElement.scrollHeight,
              document.body.offsetHeight,
              document.documentElement.offsetHeight
            )
            """
            webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self else {
                    return
                }

                Task { @MainActor in
                    if let height = result as? Double {
                        self.setHeight(CGFloat(height))
                    } else if let height = result as? Int {
                        self.setHeight(CGFloat(height))
                    }
                }
            }
        }

        @MainActor
        private func setHeight(_ height: CGFloat) {
            let clampedHeight = min(max(height.rounded(.up), 160), 50_000)
            guard abs(contentHeight.wrappedValue - clampedHeight) > 1 else {
                return
            }

            contentHeight.wrappedValue = clampedHeight
        }
    }
}
