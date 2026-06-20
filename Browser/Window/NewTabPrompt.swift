import AppKit
import SwiftUI

struct NewTabPrompt: View {
    @ObservedObject var browser: BrowserState

    let bezelStyle: BrowserBezelStyle
    let initialAddressText: String
    let selectsInitialText: Bool
    let suggestionMode: NewTabPromptSuggestionMode
    let onSubmit: (String) -> Bool
    let onSwitchToTab: (BrowserTab.ID) -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool
    @State private var addressText = ""
    @State private var selectedSuggestionID: String?
    @State private var arrowKeyMonitor: Any?

    private var trimmedAddress: String {
        addressText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var suggestions: [NewTabPromptSuggestion] {
        let query = normalizedQuery(trimmedAddress)
        let openTabURLs = Set(browser.tabs.compactMap { $0.url?.absoluteString })
        let openTabs = openTabSuggestions(query: query)
            .map(NewTabPromptSuggestion.openTab)

        let siteSuggestions = siteSuggestions(query: query)
            .map(NewTabPromptSuggestion.site)

        let pageSuggestions = pageSuggestions(query: query, openTabURLs: openTabURLs)
            .map(NewTabPromptSuggestion.page)

        return Array((openTabs + siteSuggestions + pageSuggestions).prefix(7))
    }

    private var selectedSuggestion: NewTabPromptSuggestion? {
        guard let selectedSuggestionID else {
            return nil
        }

        return suggestions.first { $0.id == selectedSuggestionID }
    }

    private var inlineCompletion: String? {
        guard selectedSuggestionID == nil,
              let suggestion = suggestions.first(where: { $0.canInlineComplete }),
              let completion = completionSuffix(for: suggestion.completionText, typedText: trimmedAddress),
              !completion.isEmpty else {
            return nil
        }

        return completion
    }

    var body: some View {
        GeometryReader { proxy in
            let paletteWidth = min(max(proxy.size.width * 0.50, 560), 760)
            let paletteTopInset = max(72, (proxy.size.height * 0.42) - 27)

            ZStack(alignment: .top) {
                Color(nsColor: browser.profileNSColor).opacity(0.24)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onCancel)

                VStack(spacing: 0) {
                    inputRow

                    if !suggestions.isEmpty {
                        Divider()
                            .overlay(Color.white.opacity(0.08))
                            .padding(.horizontal, 12)

                        VStack(spacing: 3) {
                            ForEach(suggestions, id: \.id) { suggestion in
                                NewTabPromptSuggestionRow(
                                    suggestion: suggestion,
                                    isSelected: suggestion.id == selectedSuggestionID,
                                    mode: suggestionMode,
                                    onHighlight: {
                                        selectedSuggestionID = suggestion.id
                                    },
                                    onSelect: {
                                        selectedSuggestionID = suggestion.id
                                        activate(suggestion)
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
                .frame(width: paletteWidth)
                .background {
                    BrowserChromeBackground(
                        bezelStyle: bezelStyle,
                        cornerRadius: 10,
                        effect: .liquidGlass(
                            style: .regular,
                            tintColor: NSColor.black.withAlphaComponent(0.12)
                        ),
                        profileColor: browser.profileNSColor
                    )
                        .shadow(color: .black.opacity(0.22), radius: 14, y: 7)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(isFocused ? 0.28 : 0.16), lineWidth: 1)
                }
                .padding(.horizontal, 16)
                .padding(.top, paletteTopInset)
                .onTapGesture {}
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onChange(of: addressText) { _, _ in
            selectedSuggestionID = nil
        }
        .onChange(of: suggestions.map(\.id)) { _, ids in
            if let selectedSuggestionID, ids.contains(selectedSuggestionID) {
                return
            }

            selectedSuggestionID = nil
        }
        .onMoveCommand { direction in
            moveSelection(direction)
        }
        .onAppear {
            addressText = initialAddressText
            DispatchQueue.main.async {
                isFocused = true
                if selectsInitialText {
                    selectFocusedText()
                }
                selectedSuggestionID = nil
            }
            installArrowKeyMonitorIfNeeded()
        }
        .onDisappear {
            removeArrowKeyMonitor()
        }
        .onExitCommand(perform: onCancel)
    }

    private var inputRow: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    Text(addressText)
                        .foregroundStyle(.clear)

                    if let inlineCompletion {
                        Text(inlineCompletion)
                            .foregroundStyle(.secondary.opacity(0.62))
                    }
                }
                .font(.system(size: 18, weight: .semibold))
                .lineLimit(1)

                TextField("Search or Enter URL...", text: $addressText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(1)
                    .focused($isFocused)
                    .onSubmit {
                        submit()
                    }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selectedSuggestionID == nil && !isFocused ? Color.primary.opacity(0.08) : Color.clear)
        }
        .onTapGesture {
            selectedSuggestionID = nil
            isFocused = true
        }
        .onHover { isHovered in
            if isHovered {
                selectedSuggestionID = nil
            }
        }
    }

    private func submit() {
        let address = trimmedAddress

        if let selectedSuggestion {
            activate(selectedSuggestion)
            return
        }

        guard !address.isEmpty else {
            return
        }

        if let suggestion = suggestions.first(where: { $0.canInlineComplete }) {
            activate(suggestion)
            return
        }

        if onSubmit(address) {
            addressText = ""
        }
    }

    private func activate(_ suggestion: NewTabPromptSuggestion) {
        switch suggestion {
        case .openTab(let tab):
            onSwitchToTab(tab.id)
        case .site(let site):
            if onSubmit(site.displayURL) {
                addressText = ""
            }
        case .page(let page):
            if onSubmit(page.url.absoluteString) {
                addressText = ""
            }
        }
    }

    private func selectFocusedText() {
        DispatchQueue.main.async {
            (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !suggestions.isEmpty else {
            selectedSuggestionID = nil
            return
        }

        let currentIndex = selectedSuggestionID.flatMap { id in
            suggestions.firstIndex { $0.id == id }
        }

        switch direction {
        case .down:
            selectedSuggestionID = suggestions[((currentIndex ?? -1) + 1) % suggestions.count].id
        case .up:
            guard let currentIndex else {
                selectedSuggestionID = suggestions.last?.id
                return
            }

            if currentIndex == 0 {
                selectedSuggestionID = nil
                isFocused = true
            } else {
                selectedSuggestionID = suggestions[currentIndex - 1].id
            }
        default:
            break
        }
    }

    private func installArrowKeyMonitorIfNeeded() {
        guard arrowKeyMonitor == nil else {
            return
        }

        arrowKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else {
                return event
            }

            switch event.keyCode {
            case 53:
                onCancel()
                return nil
            case 36, 76:
                submit()
                return nil
            case 48:
                acceptInlineCompletion()
                return nil
            case 125:
                moveSelection(.down)
                return nil
            case 126:
                moveSelection(.up)
                return nil
            default:
                return event
            }
        }
    }

    private func removeArrowKeyMonitor() {
        guard let arrowKeyMonitor else {
            return
        }

        NSEvent.removeMonitor(arrowKeyMonitor)
        self.arrowKeyMonitor = nil
    }

    private func acceptInlineCompletion() {
        guard let suggestion = suggestions.first(where: { $0.canInlineComplete }) else {
            return
        }

        addressText = suggestion.completionText
        selectedSuggestionID = nil
        isFocused = true
    }

    private func openTabSuggestions(query: String) -> [BrowserTab] {
        let tabs = browser.tabs.filter { $0.url != nil && $0.id != browser.selectedTabID }
        guard !query.isEmpty else {
            return Array(tabs.prefix(3))
        }

        let strictMatches = tabs.filter { tabMatches($0, query: query, allowWWWFallback: false) }
        let matches = strictMatches.isEmpty
            ? tabs.filter { tabMatches($0, query: query, allowWWWFallback: true) }
            : strictMatches

        return Array(matches.sorted { lhs, rhs in
            tabScore(lhs, query: query) > tabScore(rhs, query: query)
        }.prefix(3))
    }

    private func siteSuggestions(query: String) -> [BrowserAutocompleteSite] {
        guard !query.isEmpty, !query.contains("/") else {
            return []
        }

        return Array(browser.autocompleteSites
            .filter { site in siteMatches(site, query: query) }
            .sorted { lhs, rhs in
                siteScore(lhs, query: query) > siteScore(rhs, query: query)
            }
            .prefix(3))
    }

    private func pageSuggestions(query: String, openTabURLs: Set<String>) -> [BrowserAutocompletePage] {
        guard !query.isEmpty else {
            return []
        }

        let topSite = siteSuggestions(query: query).first
        let shouldSuggestDomainPages = topSite.map { query == normalizedQuery($0.host) || query == normalizedQuery($0.registrableDomain) } ?? false
        let containsPathIntent = query.contains("/") || query.contains(" ")

        guard shouldSuggestDomainPages || containsPathIntent else {
            return []
        }

        return Array(browser.autocompletePages
            .filter { page in
                !openTabURLs.contains(page.url.absoluteString)
                    && pageMatches(page, query: query, preferredSite: topSite)
            }
            .sorted { lhs, rhs in
                pageScore(lhs, query: query, preferredSite: topSite) > pageScore(rhs, query: query, preferredSite: topSite)
            }
            .prefix(3))
    }

    private func tabMatches(_ tab: BrowserTab, query: String, allowWWWFallback: Bool) -> Bool {
        let title = normalizedQuery(tab.displayTitle)
        let address = normalizedQuery(tab.addressText)
        let host = normalizedHost(tab.url?.host() ?? "")
        let hostForMatch = allowWWWFallback ? host.removingWWWPrefix : host
        return title.contains(query) || address.contains(query) || hostForMatch.contains(query)
    }

    private func tabScore(_ tab: BrowserTab, query: String) -> Int {
        let host = normalizedHost(tab.url?.host() ?? "")
        let title = normalizedQuery(tab.displayTitle)
        if host == query { return 1000 }
        if host.hasPrefix(query) { return 800 }
        if title.hasPrefix(query) { return 600 }
        if host.contains(query) { return 450 }
        if title.contains(query) { return 300 }
        return 0
    }

    private func siteMatches(_ site: BrowserAutocompleteSite, query: String) -> Bool {
        normalizedQuery(site.host).contains(query)
            || normalizedQuery(site.registrableDomain).contains(query)
            || normalizedQuery(site.subdomain ?? "").contains(query)
            || normalizedQuery(site.displayTitle).contains(query)
    }

    private func siteScore(_ site: BrowserAutocompleteSite, query: String) -> Int {
        let host = normalizedQuery(site.host)
        let domain = normalizedQuery(site.registrableDomain)
        let subdomain = normalizedQuery(site.subdomain ?? "")
        let matchScore: Int
        if host == query || domain == query || subdomain == query {
            matchScore = 2000
        } else if host.hasPrefix(query) || domain.hasPrefix(query) || subdomain.hasPrefix(query) {
            matchScore = 1500
        } else {
            matchScore = 800
        }

        return matchScore + min(site.visitCount, 500)
    }

    private func pageMatches(_ page: BrowserAutocompletePage, query: String, preferredSite: BrowserAutocompleteSite?) -> Bool {
        if let preferredSite, page.host == preferredSite.host {
            return true
        }

        return normalizedQuery(page.displayTitle).contains(query)
            || normalizedQuery(page.displayURL).contains(query)
            || normalizedQuery(page.host).contains(query)
    }

    private func pageScore(_ page: BrowserAutocompletePage, query: String, preferredSite: BrowserAutocompleteSite?) -> Int {
        let preferredBoost = preferredSite?.host == page.host ? 1000 : 0
        let title = normalizedQuery(page.displayTitle)
        let url = normalizedQuery(page.displayURL)
        let matchScore = title.hasPrefix(query) || url.hasPrefix(query) ? 600 : 250
        return preferredBoost + matchScore + min(page.visitCount, 500)
    }

    private func completionSuffix(for completionText: String, typedText: String) -> String? {
        guard !typedText.isEmpty,
              completionText.lowercased().hasPrefix(typedText.lowercased()),
              completionText.count > typedText.count else {
            return nil
        }

        return String(completionText.dropFirst(typedText.count))
    }

    private func normalizedQuery(_ value: String) -> String {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("http://") {
            value.removeFirst(7)
        } else if value.hasPrefix("https://") {
            value.removeFirst(8)
        }
        return value.removingWWWPrefix
    }

    private func normalizedHost(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

@MainActor
enum NewTabPromptSuggestionMode {
    case openNewTab
    case navigate
}

@MainActor
private enum NewTabPromptSuggestion {
    case openTab(BrowserTab)
    case site(BrowserAutocompleteSite)
    case page(BrowserAutocompletePage)

    var id: String {
        switch self {
        case .openTab(let tab):
            return "tab-\(tab.id.uuidString)"
        case .site(let site):
            return "site-\(site.id)"
        case .page(let page):
            return "page-\(page.id)"
        }
    }

    var title: String {
        switch self {
        case .openTab(let tab):
            return tab.displayTitle
        case .site(let site):
            return site.displayTitle
        case .page(let page):
            return page.displayTitle
        }
    }

    var subtitle: String {
        switch self {
        case .openTab(let tab):
            return tab.addressText
        case .site(let site):
            return site.displayURL
        case .page(let page):
            return page.displayURL
        }
    }

    var completionText: String {
        switch self {
        case .openTab(let tab):
            return tab.addressText
        case .site(let site):
            return site.displayURL
        case .page(let page):
            return page.displayURL
        }
    }

    var canInlineComplete: Bool {
        switch self {
        case .openTab:
            return false
        case .site, .page:
            return true
        }
    }

    var favicon: NSImage? {
        switch self {
        case .openTab(let tab):
            return tab.favicon
        case .site(let site):
            return site.favicon
        case .page(let page):
            return page.favicon
        }
    }

    func actionTitle(mode: NewTabPromptSuggestionMode) -> String? {
        if mode == .navigate {
            return "Navigate"
        }

        switch self {
        case .openTab:
            return "Switch to Tab"
        case .site:
            return nil
        case .page:
            return nil
        }
    }

    func actionIconName(mode: NewTabPromptSuggestionMode) -> String {
        if mode == .navigate {
            return "arrow.forward"
        }

        switch self {
        case .openTab:
            return "arrow.right"
        case .site:
            return "globe"
        case .page:
            return "clock.arrow.circlepath"
        }
    }
}

private struct NewTabPromptSuggestionRow: View {
    let suggestion: NewTabPromptSuggestion
    let isSelected: Bool
    let mode: NewTabPromptSuggestionMode
    let onHighlight: () -> Void
    let onSelect: () -> Void

    var body: some View {
        Button {
            onHighlight()
            onSelect()
        } label: {
            HStack(spacing: 9) {
                NewTabPromptSuggestionIcon(suggestion: suggestion, isSelected: isSelected)

                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if !suggestion.subtitle.isEmpty {
                        Text(suggestion.subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let actionTitle = suggestion.actionTitle(mode: mode) {
                    Text(actionTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                }

                Image(systemName: suggestion.actionIconName(mode: mode))
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSelected ? Color.white.opacity(0.92) : Color.primary.opacity(0.08))
                    }
                    .foregroundStyle(isSelected ? Color.black.opacity(0.72) : Color.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 50)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.24) : Color.clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            NewTabPromptPointerMovedRegion(onMoved: onHighlight)
                .allowsHitTesting(false)
        }
    }
}

private struct NewTabPromptPointerMovedRegion: NSViewRepresentable {
    let onMoved: () -> Void

    func makeNSView(context: Context) -> NewTabPromptPointerMovedView {
        let view = NewTabPromptPointerMovedView()
        view.onMoved = onMoved
        return view
    }

    func updateNSView(_ nsView: NewTabPromptPointerMovedView, context: Context) {
        nsView.onMoved = onMoved
    }
}

private final class NewTabPromptPointerMovedView: NSView {
    var onMoved: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        onMoved?()
    }
}

private struct NewTabPromptSuggestionIcon: View {
    let suggestion: NewTabPromptSuggestion
    let isSelected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.9) : Color.primary.opacity(0.08))

            if let favicon = suggestion.favicon {
                Image(nsImage: favicon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isSelected ? Color.black.opacity(0.65) : Color.secondary)
            }
        }
        .frame(width: 32, height: 32)
    }
}
