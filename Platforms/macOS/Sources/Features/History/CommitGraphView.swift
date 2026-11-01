import FoldGitCore
import SwiftUI

struct CommitGraphView: View {
    var logStore: HistoryStore
    @Binding var selectionLogID: String?
    @Binding var subSelectionLogID: String?
    @Binding var showing: RepositoryPresentation
    @Binding var isRefresh: Bool
    @State private var isLoading = false
    @State private var positionedCommits: [PositionedCommit] = []

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        CommitGraphContentView(
                            selectionLogID: $selectionLogID,
                            subSelectionLogID: $subSelectionLogID,
                            logStore: logStore,
                            showing: $showing,
                            isRefresh: $isRefresh,
                            commits: positionedCommits,
                            viewportWidth: geometry.size.width
                        )
                        if logStore.canLoadMore {
                            HStack {
                                if isLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Button("Load More") {
                                        Task {
                                            isLoading = true
                                            await logStore.loadMore()
                                            isLoading = false
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                                Spacer()
                            }
                            .padding()
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .task(id: logStore.scrollRequest?.id) {
                guard let request = logStore.scrollRequest else { return }
                await Task.yield()
                proxy.scrollTo(request.target, anchor: .topLeading)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .focusable()
        .focusEffectDisabled()
        .onChange(of: logStore.logs(), initial: true) { rebuildGraph() }
        .onChange(of: logStore.snapshot?.headHash) { rebuildGraph() }
        .onMoveCommand { direction in
            guard let selectionLogID, let index = positionedCommits.firstIndex(where: { $0.id == selectionLogID }) else { return }
            switch direction {
            case .down:
                if index + 1 < positionedCommits.count { self.selectionLogID = positionedCommits[index + 1].id }
            case .up:
                if index > 0 { self.selectionLogID = positionedCommits[index - 1].id }
            case .left, .right:
                break
            @unknown default:
                break
            }
        }
    }

    private func rebuildGraph() {
        positionedCommits = CommitGraph().positionedHistory(logStore.commits, headHash: logStore.snapshot?.headHash,
            showsWorkingTree: logStore.searchText.isEmpty && logStore.notCommitted?.isEmpty == false)
    }
}

struct CommitGraphContentView: View {
    @Environment(\.worktreeVisibility) private var worktreeVisibility
    @Environment(\.folder) private var folder
    @Environment(\.appearsActive) private var appearsActive
    @AppStorage(PreferenceKey.commitGraphDensity.rawValue) private var density = CommitGraphDensity.comfortable
    @Binding var selectionLogID: String?
    @Binding var subSelectionLogID: String?
    var logStore: HistoryStore
    @Binding var showing: RepositoryPresentation
    @Binding var isRefresh: Bool
    @State private var error: Error?
    var commits: [PositionedCommit]
    var viewportWidth: CGFloat = 380

    private var metrics: CommitGraphMetrics { density.metrics }

    var body: some View {
        let metrics = metrics
        let maximumTextLeading = commits.lazy.map { metrics.textLeading(for: $0) }.max()
            ?? metrics.x(column: 0) + metrics.textGap
        let workingTreeWidth = max(0, viewportWidth - 16)
        let rowWidth = max(workingTreeWidth, maximumTextLeading + 220 + 10)
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(commits) { positioned in
                if positioned.id == Log.notCommitted.id {
                    workingTreeRow(positioned, rowWidth: rowWidth, metrics: metrics)
                        .id(positioned.id)
                } else if let folder {
                    row(positioned, rowWidth: rowWidth, metrics: metrics)
                        .id(positioned.id)
                        .commitContextMenu(
                            folder: folder, commit: positioned.commit, logStore: logStore,
                            isRefresh: $isRefresh, showing: $showing, bindingError: $error
                        )
                } else {
                    row(positioned, rowWidth: rowWidth, metrics: metrics)
                        .id(positioned.id)
                }
            }
        }
        .frame(width: rowWidth, alignment: .leading)
        .padding(.horizontal, 8)
        .errorSheet($error, operation: "Commit History")
    }

    private func workingTreeRow(_ positioned: PositionedCommit, rowWidth: CGFloat, metrics: CommitGraphMetrics) -> some View {
        let iconSize = metrics.workingTreeIconSize
        return HStack(alignment: metrics.isSingleLine ? .center : .top, spacing: 0) {
            CommitGraphLaneView(positioned: positioned, showsNode: false, metrics: metrics)
                .overlay {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: iconSize * 0.55, weight: .medium))
                        .foregroundStyle(.orange)
                        .frame(width: iconSize, height: iconSize)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: iconSize / 4))
                        .overlay { RoundedRectangle(cornerRadius: iconSize / 4).strokeBorder(Color.orange.opacity(0.4)) }
                        .position(x: metrics.x(column: positioned.column), y: metrics.nodeY)
                }
                .frame(width: metrics.textLeading(for: positioned), height: metrics.rowHeight)
                .accessibilityHidden(true)
            UncommittedChangesLabel(showsIcon: false)
                .padding(.top, metrics.titleTop)
            Spacer(minLength: 8)
        }
        .frame(width: rowWidth, height: metrics.rowHeight)
        .background {
            UncommittedChangesBackground(isSelected: isSelected(Log.notCommitted.id))
                .padding(.bottom, metrics.isSingleLine ? 2 : 4)
        }
        .contentShape(Rectangle())
        .tapGesture(logID: Log.notCommitted.id, selectionLogID: $selectionLogID, subSelectionLogID: $subSelectionLogID)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected(Log.notCommitted.id) ? [.isSelected] : [])
    }

    private func row(_ positioned: PositionedCommit, rowWidth: CGFloat, metrics: CommitGraphMetrics) -> some View {
        let selected = isSelected(positioned.id)
        let textLeading = metrics.textLeading(for: positioned)
        let textWidth = max(220, viewportWidth - 16 - textLeading - 10)
        return HStack(alignment: metrics.isSingleLine ? .center : .top, spacing: 0) {
            CommitGraphLaneView(positioned: positioned, isSelected: selected, metrics: metrics)
                .frame(width: textLeading, height: metrics.rowHeight)
                .accessibilityHidden(true)
            Group {
                if metrics.isSingleLine {
                    singleLineText(positioned, selected: selected)
                } else {
                    VStack(alignment: .leading, spacing: metrics.density == .compact ? 2 : 3) {
                        title(positioned, selected: selected, lineLimit: metrics.titleLineLimit)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 6) {
                            CommitSyncBadge(incoming: logStore.isIncoming(positioned.id), outgoing: logStore.isOutgoing(positioned.id))
                            hash(positioned)
                            author(positioned)
                            date(positioned)
                            branch(positioned)
                        }
                    }
                    .padding(.top, metrics.titleTop)
                }
            }
            .frame(width: textWidth, alignment: .leading)
            Spacer(minLength: 10)
        }
        .frame(width: rowWidth, height: metrics.rowHeight)
        .background(selectionBackground(for: positioned.id), in: RoundedRectangle(cornerRadius: metrics.selectionCornerRadius))
        .contentShape(Rectangle())
        .tapGesture(logID: positioned.id, selectionLogID: $selectionLogID, subSelectionLogID: $subSelectionLogID)
        .help(positioned.commit.title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// Branch label and title on the left, details on the right. Narrow rows drop the author, then the hash.
    private func singleLineText(_ positioned: PositionedCommit, selected: Bool) -> some View {
        HStack(spacing: 6) {
            branch(positioned, maximumCharacters: 24).fixedSize()
            title(positioned, selected: selected, lineLimit: 1)
                .layoutPriority(1)
            Spacer(minLength: 6)
            ViewThatFits(in: .horizontal) {
                singleLineDetails(positioned, showsHash: true, showsAuthor: true)
                singleLineDetails(positioned, showsHash: true, showsAuthor: false)
                singleLineDetails(positioned, showsHash: false, showsAuthor: false)
            }
        }
    }

    private func singleLineDetails(_ positioned: PositionedCommit, showsHash: Bool, showsAuthor: Bool) -> some View {
        HStack(spacing: 6) {
            CommitSyncBadge(incoming: logStore.isIncoming(positioned.id), outgoing: logStore.isOutgoing(positioned.id))
            if showsHash { hash(positioned) }
            if showsAuthor { author(positioned).frame(maxWidth: 120).fixedSize() }
            date(positioned)
        }
        .fixedSize()
    }

    private func title(_ positioned: PositionedCommit, selected: Bool, lineLimit: Int) -> some View {
        Text(positioned.commit.title)
            .font(.callout)
            .fontWeight(selected ? .medium : .regular)
            .foregroundStyle(logStore.isOutsideCurrentBranch(positioned.id) && !selected ? .secondary : .primary)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
    }

    private func hash(_ positioned: PositionedCommit) -> some View {
        Text(positioned.id.prefix(7))
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private func author(_ positioned: PositionedCommit) -> some View {
        Text(positioned.commit.author)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(Text(verbatim: "\(positioned.commit.author) <\(positioned.commit.authorEmail)>"))
    }

    private func date(_ positioned: PositionedCommit) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            Text(positioned.commit.authorDateRelative)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize()
                .help(positioned.commit.authorDateDisplay)
        }
    }

    /// A character limit keeps single-line labels from pushing out the title without reserving space on rows without one.
    @ViewBuilder private func branch(_ positioned: PositionedCommit, maximumCharacters: Int? = nil) -> some View {
        if let name = worktreeVisibility.decorations(positioned.commit.branches).first {
            Label(Self.shortened(name, to: maximumCharacters), image: "git.branch")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(CommitGraphStyle.color(index: positioned.colorIndex))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(-1)
        }
    }

    static func shortened(_ name: String, to limit: Int?) -> String {
        guard let limit, name.count > limit, limit > 2 else { return name }
        let head = (limit - 1) / 2
        return String(name.prefix(head)) + "…" + String(name.suffix(limit - 1 - head))
    }

    private func isSelected(_ id: String) -> Bool {
        id == selectionLogID || id == subSelectionLogID
    }

    private func selectionBackground(for id: String) -> Color {
        guard isSelected(id) else { return .clear }
        return appearsActive ? Color.accentColor.opacity(0.12) : Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.5)
    }

}

/// Row density of the commit history. Comfortable matches the original layout.
enum CommitGraphDensity: String, CaseIterable, Identifiable {
    case comfortable
    case compact
    case singleLine

    var id: Self { self }

    var title: String {
        switch self {
        case .comfortable: String(localized: "Comfortable")
        case .compact: String(localized: "Compact")
        case .singleLine: String(localized: "Single Line")
        }
    }

    var metrics: CommitGraphMetrics {
        switch self {
        case .comfortable: .comfortable
        case .compact: .compact
        case .singleLine: .singleLine
        }
    }
}

/// Every size that depends on the row density: lanes, nodes, curves and text placement.
struct CommitGraphMetrics: Equatable {
    var density: CommitGraphDensity
    var rowHeight: CGFloat
    var laneSpacing: CGFloat
    var nodeY: CGFloat
    var titleTop: CGFloat
    var textGap: CGFloat
    var nodeSize: CGFloat
    var haloSize: CGFloat
    var cornerRadius: CGFloat
    var boundaryInset: CGFloat
    var titleLineLimit: Int
    var leadingInset: CGFloat = 16

    static let comfortable = Self(density: .comfortable, rowHeight: 56, laneSpacing: 18, nodeY: 16, titleTop: 8, textGap: 18,
                                  nodeSize: 9, haloSize: 18, cornerRadius: 7, boundaryInset: 8, titleLineLimit: 2)
    static let compact = Self(density: .compact, rowHeight: 40, laneSpacing: 16, nodeY: 13, titleTop: 5, textGap: 16,
                              nodeSize: 8, haloSize: 16, cornerRadius: 6, boundaryInset: 6, titleLineLimit: 1)
    static let singleLine = Self(density: .singleLine, rowHeight: 26, laneSpacing: 14, nodeY: 13, titleTop: 0, textGap: 14,
                                 nodeSize: 7, haloSize: 14, cornerRadius: 4, boundaryInset: 4, titleLineLimit: 1)

    var isSingleLine: Bool { density == .singleLine }
    var selectionCornerRadius: CGFloat { min(8, rowHeight / 3) }
    var workingTreeIconSize: CGFloat { min(20, rowHeight - 6) }

    func x(column: Int) -> CGFloat {
        leadingInset + CGFloat(column) * laneSpacing
    }

    func gutterWidth(columnCount: Int) -> CGFloat {
        leadingInset * 2 + CGFloat(max(0, columnCount - 1)) * laneSpacing
    }

    func textLeading(for positioned: PositionedCommit) -> CGFloat {
        // Include passing lanes and merge bends so labels never cover branch paths.
        x(column: positioned.columnCount - 1) + textGap
    }

    func y(_ position: CommitGraphSegment.Position) -> CGFloat {
        switch position {
        case .top: 0
        case .node: nodeY
        case .bottom: rowHeight
        case .boundary: rowHeight - boundaryInset
        }
    }

    func path(for segment: CommitGraphSegment) -> Path {
        let start = CGPoint(x: x(column: segment.fromColumn), y: y(segment.start))
        let end = CGPoint(x: x(column: segment.toColumn), y: y(segment.end))
        return Path { path in
            path.move(to: start)
            if start.x == end.x {
                path.addLine(to: end)
            } else if segment.start == .node {
                let corner = CGPoint(x: end.x, y: (start.y + end.y) / 2)
                let deltaX = corner.x - start.x
                let deltaY = corner.y - start.y
                let diagonalLength = hypot(deltaX, deltaY)
                let radius = min(cornerRadius, diagonalLength / 2, end.y - corner.y)
                path.addLine(to: CGPoint(x: corner.x - deltaX / diagonalLength * radius,
                                         y: corner.y - deltaY / diagonalLength * radius))
                path.addQuadCurve(to: CGPoint(x: corner.x, y: corner.y + radius), control: corner)
                path.addLine(to: end)
            } else {
                let diagonalHeight = min((end.y - start.y) / 2, (rowHeight - nodeY) / 2)
                let corner = CGPoint(x: start.x, y: end.y - diagonalHeight)
                let deltaX = end.x - corner.x
                let deltaY = end.y - corner.y
                let diagonalLength = hypot(deltaX, deltaY)
                let radius = min(cornerRadius, diagonalLength / 2, corner.y - start.y)
                path.addLine(to: CGPoint(x: corner.x, y: corner.y - radius))
                path.addQuadCurve(to: CGPoint(x: corner.x + deltaX / diagonalLength * radius,
                                              y: corner.y + deltaY / diagonalLength * radius), control: corner)
                path.addLine(to: end)
            }
        }
    }
}

/// Density-independent drawing values, plus the comfortable geometry for callers that do not follow the setting.
enum CommitGraphStyle {
    static let lineWidth: CGFloat = 1.8
    static let leadingInset: CGFloat = CommitGraphMetrics.comfortable.leadingInset
    static let rowHeight: CGFloat = CommitGraphMetrics.comfortable.rowHeight
    static let laneSpacing: CGFloat = CommitGraphMetrics.comfortable.laneSpacing
    static let nodeY: CGFloat = CommitGraphMetrics.comfortable.nodeY
    static let titleTop: CGFloat = CommitGraphMetrics.comfortable.titleTop
    static let textGap: CGFloat = CommitGraphMetrics.comfortable.textGap

    static func x(column: Int) -> CGFloat { CommitGraphMetrics.comfortable.x(column: column) }
    static func gutterWidth(columnCount: Int) -> CGFloat { CommitGraphMetrics.comfortable.gutterWidth(columnCount: columnCount) }
    static func textLeading(for positioned: PositionedCommit) -> CGFloat { CommitGraphMetrics.comfortable.textLeading(for: positioned) }
    static func y(_ position: CommitGraphSegment.Position) -> CGFloat { CommitGraphMetrics.comfortable.y(position) }
    static func path(for segment: CommitGraphSegment) -> Path { CommitGraphMetrics.comfortable.path(for: segment) }

    static func color(index: Int) -> Color {
        let colors: [NSColor] = [.systemBlue, .systemPurple, .systemTeal, .systemOrange,
                                 .systemPink, .systemGreen, .systemIndigo, .systemBrown]
        return Color(nsColor: colors[index % colors.count])
    }
}

struct CommitGraphLaneView: View {
    let positioned: PositionedCommit
    var isSelected = false
    var showsNode = true
    var metrics = CommitGraphMetrics.comfortable

    var body: some View {
        Canvas { context, _ in
            let nodeX = metrics.x(column: positioned.column)
            // Associate every label with its commit node, including single-lane rows.
            let guide = Path { path in
                path.move(to: CGPoint(x: nodeX + metrics.haloSize / 2, y: metrics.nodeY))
                path.addLine(to: CGPoint(x: metrics.textLeading(for: positioned) - 3,
                                        y: metrics.nodeY))
            }
            context.stroke(guide, with: .color(CommitGraphStyle.color(index: positioned.colorIndex).opacity(isSelected ? 0.6 : 0.35)),
                           style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 3]))
            for segment in positioned.segments {
                let color = CommitGraphStyle.color(index: segment.colorIndex)
                context.stroke(metrics.path(for: segment),
                               with: .color(color.opacity(segment.isBoundary ? 0.45 : 0.8)),
                               style: StrokeStyle(lineWidth: CommitGraphStyle.lineWidth,
                                                  lineCap: .round, lineJoin: .round,
                                                  dash: segment.isBoundary ? [2, 3] : []))
            }
            guard showsNode else { return }
            let center = CGPoint(x: nodeX, y: metrics.nodeY)
            let color = CommitGraphStyle.color(index: positioned.colorIndex)
            if isSelected {
                let halo = Path(ellipseIn: CGRect(x: center.x - metrics.haloSize / 2, y: center.y - metrics.haloSize / 2,
                                                  width: metrics.haloSize, height: metrics.haloSize))
                context.fill(halo, with: .color(color.opacity(0.15)))
            }
            let size: CGFloat = positioned.commit.parentHashes.filter { !$0.isEmpty }.count > 1 ? metrics.nodeSize + 2 : metrics.nodeSize
            let node = Path(ellipseIn: CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
            let surround = Path(ellipseIn: CGRect(x: center.x - size / 2 - 2, y: center.y - size / 2 - 2, width: size + 4, height: size + 4))
            context.fill(surround, with: .color(Color(nsColor: .textBackgroundColor)))
            if positioned.commit.parentHashes.filter({ !$0.isEmpty }).count > 1 {
                context.fill(node, with: .color(Color(nsColor: .textBackgroundColor)))
                context.stroke(node, with: .color(color), lineWidth: 2)
            } else {
                context.fill(node, with: .color(color))
            }
        }
    }
}

#Preview {
    @Previewable @State var selectionLogID: String?
    @Previewable @State var subSelectionLogID: String?
    @Previewable @State var logStore = HistoryStore()
    @Previewable @State var showing = RepositoryPresentation()
    @Previewable @State var isRefresh = false

    let sampleCommits = [
        Commit(hash: "d", parentHashes: ["b", "c"], author: "Dave", authorEmail: "", authorDate: "2023-10-04T12:00:00Z", title: "Merge feature", body: "", branches: [], tags: []),
        Commit(hash: "c", parentHashes: ["b"], author: "Carol", authorEmail: "", authorDate: "2023-10-03T12:00:00Z", title: "Fix bug Fix bug Fix bug Fix bug Fix bug Fix bug Fix bug Fix bug Fix bug", body: "", branches: [], tags: []),
        Commit(hash: "b", parentHashes: ["a"], author: "Bob", authorEmail: "", authorDate: "2023-10-02T12:00:00Z", title: "Add feature", body: "", branches: [], tags: []),
        Commit(hash: "a", parentHashes: [], author: "Alice", authorEmail: "", authorDate: "2023-10-01T12:00:00Z", title: "Initial commit", body: "", branches: [], tags: [])
    ]

    CommitGraphContentView(
        selectionLogID: $selectionLogID,
        subSelectionLogID: $subSelectionLogID,
        logStore: logStore,
        showing: $showing,
        isRefresh: $isRefresh,
        commits: CommitGraph().positionedHistory(sampleCommits, headHash: sampleCommits.first?.hash, showsWorkingTree: true)
    )
    .environment(\.folder, URL(string: "file:///tmp/FoldGit/"))
        .background(Color(NSColor.textBackgroundColor))
        .frame(width: 400, height: 600)
}

#Preview {
    @Previewable @State var selectionLogID: String?
    @Previewable @State var subSelectionLogID: String?
    @Previewable @State var logStore = HistoryStore()
    @Previewable @State var showing = RepositoryPresentation()
    @Previewable @State var isRefresh = false

    let sampleCommits2 = [
        Commit(hash: "f", parentHashes: ["d", "e"], author: "Frank", authorEmail: "", authorDate: "2023-10-06T12:00:00Z", title: "Merge bugfix", body: "", branches: [], tags: []),
        Commit(hash: "e", parentHashes: ["c"], author: "Eve", authorEmail: "", authorDate: "2023-10-05T12:00:00Z", title: "Bugfix", body: "", branches: [], tags: []),
        Commit(hash: "d", parentHashes: ["b", "c"], author: "Dave", authorEmail: "", authorDate: "2023-10-04T12:00:00Z", title: "Merge feature", body: "", branches: [], tags: []),
        Commit(hash: "c", parentHashes: ["b"], author: "Carol", authorEmail: "", authorDate: "2023-10-03T12:00:00Z", title: "Fix bug", body: "", branches: [], tags: []),
        Commit(hash: "b", parentHashes: ["a"], author: "Bob", authorEmail: "", authorDate: "2023-10-02T12:00:00Z", title: "Add feature", body: "", branches: [], tags: []),
        Commit(hash: "a", parentHashes: [], author: "Alice", authorEmail: "", authorDate: "2023-10-01T12:00:00Z", title: "Initial commit", body: "", branches: [], tags: [])
    ]

    CommitGraphContentView(
        selectionLogID: $selectionLogID,
        subSelectionLogID: $subSelectionLogID,
        logStore: logStore,
        showing: $showing,
        isRefresh: $isRefresh,
        commits: CommitGraph().positionedHistory(sampleCommits2, headHash: sampleCommits2.first?.hash, showsWorkingTree: false)
    )
    .environment(\.folder, URL(string: "file:///tmp/FoldGit/"))
        .background(Color(NSColor.textBackgroundColor))
        .frame(width: 400, height: 600)
}

#Preview("In Search") {
    @Previewable @State var selectionLogID: String?
    @Previewable @State var subSelectionLogID: String?
    @Previewable @State var logStore = HistoryStore()
    @Previewable @State var showing = RepositoryPresentation()
    @Previewable @State var isRefresh = false

    let sampleCommitsInSearch = [
        Commit(hash: "f", parentHashes: ["d", "e"], author: "Frank", authorEmail: "", authorDate: "2023-10-06T12:00:00Z", title: "Merge bugfix", body: "", branches: [], tags: []),
        Commit(hash: "e", parentHashes: ["c"], author: "Eve", authorEmail: "", authorDate: "2023-10-05T12:00:00Z", title: "Bugfix", body: "", branches: [], tags: []),
        Commit(hash: "d", parentHashes: ["b", "c"], author: "Dave", authorEmail: "", authorDate: "2023-10-04T12:00:00Z", title: "Merge feature", body: "", branches: [], tags: []),
        Commit(hash: "x", parentHashes: ["b"], author: "Carol", authorEmail: "", authorDate: "2023-10-03T12:00:00Z", title: "Fix bug", body: "", branches: [], tags: []),
        Commit(hash: "b", parentHashes: ["a"], author: "Bob", authorEmail: "", authorDate: "2023-10-02T12:00:00Z", title: "Add feature", body: "", branches: [], tags: []),
        Commit(hash: "a'", parentHashes: [], author: "Alice", authorEmail: "", authorDate: "2023-10-01T12:00:00Z", title: "Initial commit", body: "", branches: [], tags: [])
    ]

    CommitGraphContentView(
        selectionLogID: $selectionLogID,
        subSelectionLogID: $subSelectionLogID,
        logStore: logStore,
        showing: $showing,
        isRefresh: $isRefresh,
        commits: CommitGraph().positionedHistory(sampleCommitsInSearch, headHash: sampleCommitsInSearch.first?.hash, showsWorkingTree: false)
    )
    .environment(\.folder, URL(string: "file:///tmp/FoldGit/"))
        .background(Color(NSColor.textBackgroundColor))
        .frame(width: 400, height: 600)
}

