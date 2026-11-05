import FoldGitCore
import SwiftUI

struct CommitGraphView: View {
    var logStore: HistoryStore
    @Binding var selectionLogID: String?
    @Binding var subSelectionLogID: String?
    @Binding var showing: RepositoryPresentation
    @Binding var isRefresh: Bool
    @State private var positionedCommits: [PositionedCommit] = []
    /// The moving end of a keyboard selection; Shift extends from the history store's anchor to it.
    @State private var cursorID: String?
    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                let contentWidth = CommitGraphStyle.contentWidth(for: positionedCommits, viewportWidth: geometry.size.width)
                let axes: Axis.Set = contentWidth > geometry.size.width ? [.horizontal, .vertical] : .vertical
                ScrollView(axes) {
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
                            // Paging starts automatically near the end; the button stays as a fallback.
                            HStack {
                                if logStore.isLoadingMore {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Button("Load More") {
                                        Task { await logStore.loadMore() }
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
                .onChange(of: geometry.size.height, initial: true) { _, height in viewportHeight = height }
            }
            .task(id: logStore.scrollRequest?.id) {
                guard let request = logStore.scrollRequest else { return }
                await Task.yield()
                proxy.scrollTo(request.target, anchor: .topLeading)
            }
            .onMoveCommand { direction in
                switch direction {
                case .down: move(by: 1, proxy: proxy)
                case .up: move(by: -1, proxy: proxy)
                case .left, .right: break
                @unknown default: break
                }
            }
            .onKeyPress(keys: [.home, .end, .pageUp, .pageDown]) { press in
                let page = max(1, Int(viewportHeight / CommitGraphStyle.rowHeight) - 1)
                let extending = press.modifiers.contains(.shift)
                switch press.key {
                case .home: move(toIndex: 0, extending: extending, proxy: proxy)
                case .end: move(toIndex: positionedCommits.count - 1, extending: extending, proxy: proxy)
                case .pageUp: move(by: -page, extending: extending, proxy: proxy)
                default: move(by: page, extending: extending, proxy: proxy)
                }
                return .handled
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .focusable()
        .focusEffectDisabled()
        .onChange(of: logStore.logs(), initial: true) { rebuildGraph() }
        .onChange(of: logStore.snapshot?.headHash) { rebuildGraph() }
        .onChange(of: selectionLogID) { _, id in
            // A click or another view moved the selection, so keyboard movement continues from there.
            if subSelectionLogID == nil { cursorID = id }
        }
    }

    private func move(by offset: Int, extending: Bool? = nil, proxy: ScrollViewProxy) {
        guard !positionedCommits.isEmpty else { return }
        let current = cursorID ?? selectionLogID
        guard let current, let index = positionedCommits.firstIndex(where: { $0.id == current }) else {
            move(toIndex: 0, extending: false, proxy: proxy)
            return
        }
        move(toIndex: index + offset, extending: extending, proxy: proxy)
    }

    private func move(toIndex target: Int, extending: Bool? = nil, proxy: ScrollViewProxy) {
        guard !positionedCommits.isEmpty else { return }
        let index = min(max(target, 0), positionedCommits.count - 1)
        let id = positionedCommits[index].id
        let extend = (extending ?? NSEvent.modifierFlags.contains(.shift)) && logStore.selectionAnchor != nil
        logStore.select(id, extending: extend, comparing: false)
        let ordered = positionedCommits.map(\.id).filter { logStore.selectedHashes.contains($0) }
        selectionLogID = ordered.first ?? id
        subSelectionLogID = ordered.count > 1 ? ordered.last : nil
        cursorID = id
        // The minimal scroll keeps the row visible without jumping when it already is.
        proxy.scrollTo(id)
        Task { await logStore.loadMoreIfApproaching(id) }
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
    @Binding var selectionLogID: String?
    @Binding var subSelectionLogID: String?
    var logStore: HistoryStore
    @Binding var showing: RepositoryPresentation
    @Binding var isRefresh: Bool
    @State private var error: Error?
    var commits: [PositionedCommit]
    var viewportWidth: CGFloat = 380

    var body: some View {
        let rowWidth = CommitGraphStyle.contentWidth(for: commits, viewportWidth: viewportWidth)
            - CommitGraphStyle.horizontalPadding * 2
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(commits) { positioned in
                if positioned.id == Log.notCommitted.id {
                    workingTreeRow(positioned, rowWidth: rowWidth)
                        .id(positioned.id)
                } else if let folder {
                    row(positioned, rowWidth: rowWidth)
                        .id(positioned.id)
                        .task { await logStore.logViewTask(.committed(positioned.commit)) }
                        .commitContextMenu(
                            folder: folder, commit: positioned.commit, logStore: logStore,
                            isRefresh: $isRefresh, showing: $showing, bindingError: $error
                        )
                } else {
                    row(positioned, rowWidth: rowWidth)
                        .id(positioned.id)
                }
            }
        }
        .frame(width: rowWidth, alignment: .leading)
        .padding(.horizontal, CommitGraphStyle.horizontalPadding)
        .errorSheet($error, operation: "Commit History")
    }

    private func workingTreeRow(_ positioned: PositionedCommit, rowWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            UncommittedChangesLabel(showsIcon: false)
            Spacer(minLength: 8)
        }
        .padding(.leading, CommitGraphStyle.textLeading(for: positioned))
        .padding(.top, CommitGraphStyle.titleTop)
        .padding(.bottom, CommitGraphStyle.textBottom)
        .frame(width: rowWidth, alignment: .leading)
        .frame(minHeight: CommitGraphStyle.rowHeight, alignment: .top)
        .background {
            UncommittedChangesBackground(isSelected: isSelected(Log.notCommitted.id))
                .padding(.vertical, 2)
        }
        .overlay(alignment: .leading) {
            CommitGraphLaneView(positioned: positioned, showsNode: false)
                .overlay {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                        .frame(width: 20, height: 20)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.orange.opacity(0.4)) }
                        .position(x: CommitGraphStyle.x(column: positioned.column), y: CommitGraphStyle.nodeY)
                }
                .frame(width: CommitGraphStyle.textLeading(for: positioned))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .tapGesture(logID: Log.notCommitted.id, selectionLogID: $selectionLogID, subSelectionLogID: $subSelectionLogID, history: logStore)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected(Log.notCommitted.id) ? [.isSelected] : [])
    }

    private func row(_ positioned: PositionedCommit, rowWidth: CGFloat) -> some View {
        let selected = isSelected(positioned.id)
        let textLeading = CommitGraphStyle.textLeading(for: positioned)
        let textWidth = max(0, rowWidth - textLeading - CommitGraphStyle.trailingInset)
        return HStack(alignment: .top, spacing: 0) {
            CommitSummaryView(
                commit: positioned.commit,
                isSelected: selected,
                outsideCurrentBranch: logStore.isOutsideCurrentBranch(positioned.id),
                incoming: logStore.isIncoming(positioned.id),
                outgoing: logStore.isOutgoing(positioned.id),
                branchName: worktreeVisibility.decorations(positioned.commit.branches).first,
                branchColor: CommitGraphStyle.color(index: positioned.colorIndex)
            )
            .frame(width: textWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: CommitGraphStyle.trailingInset)
        }
        .padding(.leading, textLeading)
        .padding(.top, CommitGraphStyle.titleTop)
        .padding(.bottom, CommitGraphStyle.textBottom)
        .frame(width: rowWidth, alignment: .leading)
        .frame(minHeight: CommitGraphStyle.rowHeight, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(selectionBackground(for: positioned.id))
                .padding(.vertical, 2)
        }
        .overlay(alignment: .leading) {
            CommitGraphLaneView(positioned: positioned, isSelected: selected)
                .frame(width: textLeading)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .tapGesture(logID: positioned.id, selectionLogID: $selectionLogID, subSelectionLogID: $subSelectionLogID, history: logStore)
        .help(positioned.commit.title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func isSelected(_ id: String) -> Bool {
        logStore.selectedHashes.contains(id) || id == selectionLogID || id == subSelectionLogID
    }

    private func selectionBackground(for id: String) -> Color {
        guard isSelected(id) else { return .clear }
        return appearsActive ? Color.accentColor.opacity(0.12) : Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.5)
    }

}

enum CommitGraphStyle {
    static let rowHeight: CGFloat = 44
    static let laneSpacing: CGFloat = 18
    static let leadingInset: CGFloat = 16
    static let lineWidth: CGFloat = 1.8
    static let nodeY: CGFloat = 14
    static let titleTop: CGFloat = 6
    static let textBottom: CGFloat = 8
    static let textGap: CGFloat = 18
    static let horizontalPadding: CGFloat = 8
    static let trailingInset: CGFloat = 10
    private static let minimumTextWidth: CGFloat = 140

    static func contentWidth(for commits: [PositionedCommit], viewportWidth: CGFloat) -> CGFloat {
        let maximumTextLeading = commits.lazy.map { textLeading(for: $0) }.max() ?? x(column: 0) + textGap
        // Let titles wrap and metadata truncate before a wide graph requires horizontal scrolling.
        return max(viewportWidth, maximumTextLeading + minimumTextWidth + trailingInset + horizontalPadding * 2)
    }

    static func x(column: Int) -> CGFloat {
        leadingInset + CGFloat(column) * laneSpacing
    }

    static func gutterWidth(columnCount: Int) -> CGFloat {
        leadingInset * 2 + CGFloat(max(0, columnCount - 1)) * laneSpacing
    }

    static func textLeading(for positioned: PositionedCommit) -> CGFloat {
        // Include passing lanes and merge bends so labels never cover branch paths.
        x(column: positioned.columnCount - 1) + textGap
    }

    static func color(index: Int) -> Color {
        let colors: [NSColor] = [.systemBlue, .systemPurple, .systemTeal, .systemOrange,
                                 .systemPink, .systemGreen, .systemIndigo, .systemBrown]
        return Color(nsColor: colors[index % colors.count])
    }

    static func y(_ position: CommitGraphSegment.Position, rowHeight: CGFloat) -> CGFloat {
        switch position {
        case .top: 0
        case .node: nodeY
        case .bottom: rowHeight
        case .boundary: rowHeight - 8
        }
    }

    static func path(for segment: CommitGraphSegment, rowHeight: CGFloat = rowHeight) -> Path {
        let start = CGPoint(x: x(column: segment.fromColumn), y: y(segment.start, rowHeight: rowHeight))
        let end = CGPoint(x: x(column: segment.toColumn), y: y(segment.end, rowHeight: rowHeight))
        return Path { path in
            path.move(to: start)
            if start.x == end.x {
                path.addLine(to: end)
            } else if segment.start == .node {
                let corner = CGPoint(x: end.x, y: (start.y + end.y) / 2)
                let deltaX = corner.x - start.x
                let deltaY = corner.y - start.y
                let diagonalLength = hypot(deltaX, deltaY)
                let radius = min(7, diagonalLength / 2, end.y - corner.y)
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
                let radius = min(7, diagonalLength / 2, corner.y - start.y)
                path.addLine(to: CGPoint(x: corner.x, y: corner.y - radius))
                path.addQuadCurve(to: CGPoint(x: corner.x + deltaX / diagonalLength * radius,
                                              y: corner.y + deltaY / diagonalLength * radius), control: corner)
                path.addLine(to: end)
            }
        }
    }
}

struct CommitGraphLaneView: View {
    let positioned: PositionedCommit
    var isSelected = false
    var showsNode = true

    var body: some View {
        Canvas { context, size in
            let nodeX = CommitGraphStyle.x(column: positioned.column)
            // Associate every label with its commit node, including single-lane rows.
            let guide = Path { path in
                path.move(to: CGPoint(x: nodeX + 9, y: CommitGraphStyle.nodeY))
                path.addLine(to: CGPoint(x: CommitGraphStyle.textLeading(for: positioned) - 3,
                                        y: CommitGraphStyle.nodeY))
            }
            context.stroke(guide, with: .color(CommitGraphStyle.color(index: positioned.colorIndex).opacity(isSelected ? 0.6 : 0.35)),
                           style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 3]))
            for segment in positioned.segments {
                let color = CommitGraphStyle.color(index: segment.colorIndex)
                context.stroke(CommitGraphStyle.path(for: segment, rowHeight: size.height),
                               with: .color(color.opacity(segment.isBoundary ? 0.45 : 0.8)),
                               style: StrokeStyle(lineWidth: CommitGraphStyle.lineWidth,
                                                  lineCap: .round, lineJoin: .round,
                                                  dash: segment.isBoundary ? [2, 3] : []))
            }
            guard showsNode else { return }
            let center = CGPoint(x: nodeX, y: CommitGraphStyle.nodeY)
            let color = CommitGraphStyle.color(index: positioned.colorIndex)
            if isSelected {
                let halo = Path(ellipseIn: CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18))
                context.fill(halo, with: .color(color.opacity(0.15)))
            }
            let size: CGFloat = positioned.commit.parentHashes.filter { !$0.isEmpty }.count > 1 ? 11 : 9
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

