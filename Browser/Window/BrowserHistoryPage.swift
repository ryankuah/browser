import AppKit
import SwiftUI

private func relativeHistoryDateText(for date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

private enum BrowserHistoryViewMode: String, CaseIterable, Identifiable {
    case journeys
    case log

    var id: Self { self }

    var title: String {
        switch self {
        case .journeys:
            return "Journeys"
        case .log:
            return "Log"
        }
    }
}

struct BrowserHistoryPage: View {
    @ObservedObject var browser: BrowserState
    let onClose: () -> Void

    @FocusState private var isSearchFocused: Bool
    @State private var query = ""
    @State private var selectedMode: BrowserHistoryViewMode = .journeys
    @State private var selectedNodeID: BrowserHistoryTreeNode.ID?
    @State private var selectedJourneyID: BrowserHistoryJourney.ID?

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredJourneys: [BrowserHistoryJourney] {
        let normalizedQuery = trimmedQuery.lowercased()
        guard !normalizedQuery.isEmpty else {
            return browser.historyJourneys
        }

        return browser.historyJourneys.compactMap { journey in
            let roots = journey.roots.compactMap { filteredNode($0, query: normalizedQuery) }
            let journeyMatches = journey.displayTitle.lowercased().contains(normalizedQuery)
            guard journeyMatches || !roots.isEmpty else {
                return nil
            }

            var filteredJourney = journey
            filteredJourney.roots = journeyMatches ? journey.roots : roots
            return filteredJourney
        }
    }

    private var filteredLogVisits: [BrowserHistoryVisit] {
        let visits = browser.historyVisits.sorted {
            if $0.visitedAt == $1.visitedAt {
                return $0.id > $1.id
            }

            return $0.visitedAt > $1.visitedAt
        }

        let normalizedQuery = trimmedQuery.lowercased()
        guard !normalizedQuery.isEmpty else {
            return visits
        }

        return visits.filter { visit in
            visit.displayTitle.lowercased().contains(normalizedQuery)
                || visit.displayURL.lowercased().contains(normalizedQuery)
                || visit.url.absoluteString.lowercased().contains(normalizedQuery)
        }
    }

    var body: some View {
        ZStack {
            BrowserChromeBackground(
                bezelStyle: browser.bezelStyle,
                cornerRadius: 0,
                effect: .liquidGlass(
                    style: .regular,
                    tintColor: NSColor.black.withAlphaComponent(0.16)
                ),
                profileColor: browser.profileNSColor
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                Divider()
                    .opacity(0.45)

                historyContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            browser.refreshHistoryEntries()
            selectedJourneyID = selectedJourneyIfAvailable(in: filteredJourneys)?.id
            DispatchQueue.main.async {
                isSearchFocused = true
            }
        }
        .onChange(of: filteredJourneys.map(\.id)) { _, _ in
            let nextJourney = selectedJourneyIfAvailable(in: filteredJourneys)
            if selectedJourneyID != nextJourney?.id {
                selectedJourneyID = nextJourney?.id
                selectedNodeID = nil
            }
        }
        .onExitCommand(perform: onClose)
    }

    @ViewBuilder
    private var historyContent: some View {
        switch selectedMode {
        case .journeys:
            journeyHistoryContent
        case .log:
            logHistoryContent
        }
    }

    @ViewBuilder
    private var journeyHistoryContent: some View {
        if filteredJourneys.isEmpty {
            emptyState(
                title: trimmedQuery.isEmpty ? "No Journeys" : "No Matches",
                message: trimmedQuery.isEmpty ? "Visited pages will appear here." : "Try another search."
            )
        } else {
            let selectedJourney = selectedJourney(in: filteredJourneys)
            HStack(spacing: 0) {
                BrowserHistoryJourneySidebar(
                    journeys: filteredJourneys,
                    selectedJourneyID: selectedJourney.id,
                    onSelect: { journey in
                        selectedJourneyID = journey.id
                        selectedNodeID = nil
                    }
                )

                Divider()
                    .opacity(0.45)

                BrowserHistoryTreeScrollView(
                    journey: selectedJourney,
                    selectedNodeID: selectedNodeID,
                    onSelect: { node in
                        selectedNodeID = node.id
                        browser.openHistoryURL(node.url, inNewTab: false)
                        onClose()
                    },
                    onOpenNewTab: { node in
                        browser.openHistoryURL(node.url, inNewTab: true)
                        onClose()
                    },
                    onCopyURL: { node in
                        browser.copyHistoryURL(node.url)
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var logHistoryContent: some View {
        if filteredLogVisits.isEmpty {
            emptyState(
                title: trimmedQuery.isEmpty ? "No History" : "No Matches",
                message: trimmedQuery.isEmpty ? "Visited pages will appear here." : "Try another search."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(filteredLogVisits) { visit in
                        BrowserHistoryLogRow(
                            visit: visit,
                            onOpenCurrent: {
                                browser.openHistoryURL(visit.url, inNewTab: false)
                                onClose()
                            },
                            onOpenNewTab: {
                                browser.openHistoryURL(visit.url, inNewTab: true)
                                onClose()
                            },
                            onCopyURL: {
                                browser.copyHistoryURL(visit.url)
                            }
                        )
                    }
                }
                .frame(maxWidth: 920)
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.visible)
        }
    }

    private func emptyState(title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.system(size: 15, weight: .semibold))

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func selectedJourney(in journeys: [BrowserHistoryJourney]) -> BrowserHistoryJourney {
        if let journey = selectedJourneyIfAvailable(in: journeys) {
            return journey
        }

        preconditionFailure("selectedJourney(in:) requires at least one journey")
    }

    private func selectedJourneyIfAvailable(in journeys: [BrowserHistoryJourney]) -> BrowserHistoryJourney? {
        guard !journeys.isEmpty else {
            return nil
        }

        if let selectedJourneyID,
           let journey = journeys.first(where: { $0.id == selectedJourneyID }) {
            return journey
        }

        return journeys.first
    }

    private func filteredNode(_ node: BrowserHistoryTreeNode, query: String) -> BrowserHistoryTreeNode? {
        let filteredChildren = node.children.compactMap { filteredNode($0, query: query) }
        let matches = node.displayTitle.lowercased().contains(query)
            || node.url.absoluteString.lowercased().contains(query)

        guard matches || !filteredChildren.isEmpty else {
            return nil
        }

        var result = node
        result.children = matches ? node.children : filteredChildren
        return result
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 15, weight: .semibold))

            Text("History")
                .font(.system(size: 16, weight: .semibold))

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField("Search History", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .focused($isSearchFocused)
            }
            .padding(.horizontal, 9)
            .frame(width: 260, height: 30)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            }

            BrowserHistoryModeSwitcher(selection: $selectedMode)

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            }
            .accessibilityLabel("Close History")
            .help("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct BrowserHistoryModeSwitcher: View {
    @Binding var selection: BrowserHistoryViewMode

    var body: some View {
        HStack(spacing: 3) {
            ForEach(BrowserHistoryViewMode.allCases) { mode in
                Button {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        selection = mode
                    }
                } label: {
                    Text(mode.title)
                        .font(.system(size: 11, weight: selection == mode ? .semibold : .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(width: 72, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == mode ? .primary : .secondary)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selection == mode ? Color.primary.opacity(0.13) : Color.clear)
                }
                .cursor(.pointingHand)
                .accessibilityLabel(mode.title)
            }
        }
        .padding(3)
        .frame(height: 30)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        }
    }
}

private struct BrowserHistoryJourneySidebar: View {
    let journeys: [BrowserHistoryJourney]
    let selectedJourneyID: BrowserHistoryJourney.ID
    let onSelect: (BrowserHistoryJourney) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 5) {
                ForEach(journeys) { journey in
                    BrowserHistoryJourneySidebarRow(
                        journey: journey,
                        isSelected: selectedJourneyID == journey.id,
                        onSelect: {
                            onSelect(journey)
                        }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.visible)
        .frame(width: 286)
        .background(Color.black.opacity(0.08))
    }
}

private struct BrowserHistoryJourneySidebarRow: View {
    let journey: BrowserHistoryJourney
    let isSelected: Bool
    let onSelect: () -> Void

    private var root: BrowserHistoryTreeNode? {
        journey.roots.min { $0.visitedAt < $1.visitedAt }
    }

    private var pageCount: Int {
        journey.roots.reduce(0) { $0 + Self.nodeCount(in: $1) }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 9) {
                BrowserHistoryIcon(favicon: root?.favicon)

                VStack(alignment: .leading, spacing: 3) {
                    Text(root?.displayTitle ?? journey.displayTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(root?.displayURL ?? "\(pageCount) pages")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 5) {
                        Text(relativeHistoryDateText(for: journey.lastVisitedAt))
                        Text("\(pageCount) \(pageCount == 1 ? "page" : "pages")")
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 9)
            .frame(height: 66)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.12 : 0.04))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.62) : Color.primary.opacity(0.06),
                    lineWidth: isSelected ? 1.4 : 1
                )
        }
        .accessibilityLabel(root?.displayTitle ?? journey.displayTitle)
    }

    private static func nodeCount(in node: BrowserHistoryTreeNode) -> Int {
        1 + node.children.reduce(0) { $0 + nodeCount(in: $1) }
    }
}

private struct BrowserHistoryTreeScrollView: View {
    let journey: BrowserHistoryJourney
    let selectedNodeID: BrowserHistoryTreeNode.ID?
    let onSelect: (BrowserHistoryTreeNode) -> Void
    let onOpenNewTab: (BrowserHistoryTreeNode) -> Void
    let onCopyURL: (BrowserHistoryTreeNode) -> Void

    var body: some View {
        GeometryReader { proxy in
            let layout = BrowserHistoryTreeLayout(journey: journey, viewportSize: proxy.size)

            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    ForEach(layout.edges) { edge in
                        BrowserHistoryTreeEdgeShape(from: edge.from, to: edge.to)
                            .stroke(
                                Color.primary.opacity(0.28),
                                style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
                            )
                            .frame(width: layout.contentSize.width, height: layout.contentSize.height)
                    }

                    ForEach(layout.nodes) { item in
                        BrowserHistoryTreeNodeCard(
                            item: item,
                            isSelected: selectedNodeID == item.node.id,
                            onSelect: {
                                onSelect(item.node)
                            },
                            onOpenNewTab: {
                                onOpenNewTab(item.node)
                            },
                            onCopyURL: {
                                onCopyURL(item.node)
                            }
                        )
                        .position(item.position)
                    }
                }
                .frame(width: layout.contentSize.width, height: layout.contentSize.height, alignment: .topLeading)
                .padding(.trailing, 32)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.visible)
        }
        .background(Color.black.opacity(0.04))
    }
}

private struct BrowserHistoryTreeEdgeShape: Shape {
    let from: CGPoint
    let to: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)

        if abs(from.x - to.x) < 1 {
            path.addLine(to: to)
        } else {
            let midpointX = from.x + max((to.x - from.x) * 0.5, 42)
            path.addLine(to: CGPoint(x: midpointX, y: from.y))
            path.addLine(to: CGPoint(x: midpointX, y: to.y))
            path.addLine(to: to)
        }

        return path
    }
}

private struct BrowserHistoryTreeLayout {
    struct NodeItem: Identifiable {
        let id: Int64
        let node: BrowserHistoryTreeNode
        let position: CGPoint
    }

    struct Edge: Identifiable {
        let id: String
        let from: CGPoint
        let to: CGPoint
    }

    private struct VerticalBounds {
        let minRow: CGFloat
        let maxRow: CGFloat
    }

    private struct StackedNode {
        let node: BrowserHistoryTreeNode
        let offsetRows: CGFloat
    }

    var nodes: [NodeItem] = []
    var edges: [Edge] = []
    var contentSize = CGSize(width: 1200, height: 800)

    private let laneWidth: CGFloat = 330
    private let verticalStep: CGFloat = 88
    private let siblingRowGap: CGFloat = 1.15
    private let nodeWidth: CGFloat = 246
    private let nodeHeight: CGFloat = 58
    private let leftInset: CGFloat = 28
    private let topInset: CGFloat = 48

    private var startX: CGFloat {
        leftInset + nodeWidth / 2
    }

    init(journey: BrowserHistoryJourney, viewportSize: CGSize) {
        let centerY = max(viewportSize.height / 2, topInset + nodeHeight / 2)

        for root in stackedNodes(journey.roots) {
            place(node: root.node, lane: 0, y: centerY + root.offsetRows * verticalStep)
        }

        normalizeVerticalPositions()

        let maxX = nodes.map(\.position.x).max() ?? startX
        let maxY = nodes.map(\.position.y).max() ?? centerY
        contentSize = CGSize(
            width: max(maxX + nodeWidth / 2 + 120, viewportSize.width),
            height: max(maxY + nodeHeight / 2 + 88, viewportSize.height)
        )
    }

    private func xPosition(for lane: Int) -> CGFloat {
        startX + CGFloat(lane) * laneWidth
    }

    private func verticalBounds(for node: BrowserHistoryTreeNode) -> VerticalBounds {
        guard !node.children.isEmpty else {
            return VerticalBounds(minRow: 0, maxRow: 0)
        }

        if node.children.count == 1, let child = node.children.first {
            let childBounds = verticalBounds(for: child)
            return VerticalBounds(
                minRow: min(0, 1 + childBounds.minRow),
                maxRow: max(0, 1 + childBounds.maxRow)
            )
        }

        let childBounds = stackedNodes(node.children).map { placement -> VerticalBounds in
            let bounds = verticalBounds(for: placement.node)
            return VerticalBounds(
                minRow: placement.offsetRows + bounds.minRow,
                maxRow: placement.offsetRows + bounds.maxRow
            )
        }

        return VerticalBounds(
            minRow: min(0, childBounds.map(\.minRow).min() ?? 0),
            maxRow: max(0, childBounds.map(\.maxRow).max() ?? 0)
        )
    }

    private func stackedNodes(_ sourceNodes: [BrowserHistoryTreeNode]) -> [StackedNode] {
        guard !sourceNodes.isEmpty else {
            return []
        }

        var cursor: CGFloat = 0
        let placements = sourceNodes.map { node -> StackedNode in
            let bounds = verticalBounds(for: node)
            let offsetRows = cursor - bounds.minRow
            cursor += (bounds.maxRow - bounds.minRow) + siblingRowGap
            return StackedNode(node: node, offsetRows: offsetRows)
        }

        let minRow = placements.map { placement in
            placement.offsetRows + verticalBounds(for: placement.node).minRow
        }.min() ?? 0
        let maxRow = placements.map { placement in
            placement.offsetRows + verticalBounds(for: placement.node).maxRow
        }.max() ?? 0
        let centerOffset = -((minRow + maxRow) / 2)

        return placements.map {
            StackedNode(node: $0.node, offsetRows: $0.offsetRows + centerOffset)
        }
    }

    private mutating func place(
        node: BrowserHistoryTreeNode,
        lane: Int,
        y: CGFloat
    ) {
        let position = CGPoint(x: xPosition(for: lane), y: y)
        nodes.append(NodeItem(id: node.id, node: node, position: position))

        guard !node.children.isEmpty else {
            return
        }

        if node.children.count == 1, let child = node.children.first {
            let childY = y + verticalStep
            place(node: child, lane: lane, y: childY)
            edges.append(
                Edge(
                    id: "\(node.id)-\(child.id)",
                    from: CGPoint(x: position.x, y: position.y + nodeHeight / 2),
                    to: CGPoint(x: position.x, y: childY - nodeHeight / 2)
                )
            )
            return
        }

        for child in stackedNodes(node.children) {
            let childPosition = CGPoint(
                x: xPosition(for: lane + 1),
                y: y + child.offsetRows * verticalStep
            )
            place(node: child.node, lane: lane + 1, y: childPosition.y)
            edges.append(
                Edge(
                    id: "\(node.id)-\(child.node.id)",
                    from: CGPoint(x: position.x + nodeWidth / 2, y: position.y),
                    to: CGPoint(x: childPosition.x - nodeWidth / 2, y: childPosition.y)
                )
            )
        }
    }

    private mutating func normalizeVerticalPositions() {
        guard let minY = nodes.map({ $0.position.y - nodeHeight / 2 }).min(),
              minY < topInset else {
            return
        }

        let offset = topInset - minY
        nodes = nodes.map { item in
            NodeItem(
                id: item.id,
                node: item.node,
                position: CGPoint(x: item.position.x, y: item.position.y + offset)
            )
        }
        edges = edges.map { edge in
            Edge(
                id: edge.id,
                from: CGPoint(x: edge.from.x, y: edge.from.y + offset),
                to: CGPoint(x: edge.to.x, y: edge.to.y + offset)
            )
        }
    }

}

private struct BrowserHistoryTreeNodeCard: View {
    let item: BrowserHistoryTreeLayout.NodeItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpenNewTab: () -> Void
    let onCopyURL: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 9) {
                BrowserHistoryIcon(favicon: item.node.favicon)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.node.displayTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(item.node.displayURL)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .frame(width: 246, height: 58)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(isHovered || isSelected ? 0.82 : 0.62))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.72) : Color.primary.opacity(isHovered ? 0.22 : 0.11),
                    lineWidth: isSelected ? 1.6 : 1
                )
        }
        .shadow(color: Color.black.opacity(isHovered ? 0.12 : 0.06), radius: isHovered ? 10 : 4, y: isHovered ? 5 : 2)
        .scaleEffect(isHovered ? 1.025 : 1)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Open", action: onSelect)
            Button("Open in New Tab", action: onOpenNewTab)
            Divider()
            Button("Copy URL", action: onCopyURL)
        }
        .accessibilityLabel(item.node.displayTitle)
        .help(item.node.url.absoluteString)
    }
}


private struct BrowserHistoryLogRow: View {
    let visit: BrowserHistoryVisit
    let onOpenCurrent: () -> Void
    let onOpenNewTab: () -> Void
    let onCopyURL: () -> Void

    @State private var isHovered = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    var body: some View {
        Button(action: onOpenCurrent) {
            HStack(spacing: 10) {
                BrowserHistoryIcon(favicon: visit.favicon)

                VStack(alignment: .leading, spacing: 2) {
                    Text(visit.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    Text(visit.displayURL)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(relativeHistoryDateText(for: visit.visitedAt))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text(Self.timeFormatter.string(from: visit.visitedAt))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 112, alignment: .trailing)

                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
            }
            .padding(.horizontal, 9)
            .frame(height: 52)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.07) : Color.clear)
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Open", action: onOpenCurrent)
            Button("Open in New Tab", action: onOpenNewTab)
            Divider()
            Button("Copy URL", action: onCopyURL)
        }
        .accessibilityLabel(visit.displayTitle)
        .help(visit.url.absoluteString)
    }

}

private struct BrowserHistoryIcon: View {
    let favicon: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.08))

            if let favicon {
                Image(nsImage: favicon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 32, height: 32)
    }
}
