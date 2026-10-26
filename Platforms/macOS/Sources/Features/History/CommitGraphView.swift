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
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    CommitGraphContentView(
                        notCommitted: .constant(logStore.searchText.isEmpty ? logStore.notCommitted : nil),
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
                                Button("More") {
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
        .background(Color(nsColor: .textBackgroundColor))
        .focusable()
        .focusEffectDisabled()
        .onChange(of: logStore.commits, initial: true) { _, commits in
            positionedCommits = CommitGraph().positionedCommits(commits)
        }
        .onMoveCommand { direction in
            guard let selectionLogID else { return }
            switch direction {
            case .down:
                if let next = logStore.nextLogID(logID: selectionLogID) {
                    self.selectionLogID = next
                }
            case .up:
                if let previous = logStore.previousLogID(logID: selectionLogID) {
                    self.selectionLogID = previous
                }
            case .left, .right:
                break
            @unknown default:
                break
            }
        }
    }
}

struct CommitGraphContentView: View {
    @Environment(\.worktreeVisibility) private var worktreeVisibility
    @Environment(\.folder) private var folder
    @Environment(\.appearsActive) private var appearsActive
    @Binding var notCommitted: NotCommitted?
    @Binding var selectionLogID: String?
    @Binding var subSelectionLogID: String?
    var logStore: HistoryStore
    @Binding var showing: RepositoryPresentation
    @Binding var isRefresh: Bool
    @State private var error: Error?
    var commits: [PositionedCommit]
    var viewportWidth: CGFloat = 380

    var body: some View {
        let maximumTextLeading = commits.lazy.map { CommitGraphStyle.textLeading(for: $0) }.max()
            ?? CommitGraphStyle.x(column: 0) + CommitGraphStyle.textGap
        let workingTreeWidth = max(0, viewportWidth - 16)
        let rowWidth = max(workingTreeWidth, maximumTextLeading + 220 + 10)
        return LazyVStack(alignment: .leading, spacing: 0) {
            if let notCommitted, !notCommitted.isEmpty {
                HStack(alignment: .top, spacing: 0) {
                    ZStack(alignment: .leading) {
                        if !commits.isEmpty {
                            Path { path in
                                let x = CommitGraphStyle.x(column: 0)
                                path.move(to: CGPoint(x: x, y: CommitGraphStyle.nodeY))
                                path.addLine(to: CGPoint(x: x, y: CommitGraphStyle.rowHeight))
                            }
                            .stroke(Color.orange.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                        }
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.orange)
                            .frame(width: 24, height: 24)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.orange.opacity(0.4))
                            }
                            .position(x: CommitGraphStyle.x(column: 0), y: CommitGraphStyle.nodeY)
                    }
                    .frame(width: CommitGraphStyle.x(column: 0) + CommitGraphStyle.textGap, height: CommitGraphStyle.rowHeight)
                    .accessibilityHidden(true)
                    UncommittedChangesLabel(showsIcon: false)
                        .padding(.top, CommitGraphStyle.titleTop)
                    Spacer(minLength: 8)
                }
                .frame(width: workingTreeWidth, height: CommitGraphStyle.rowHeight)
                .background {
                    UncommittedChangesBackground(isSelected: isSelected(Log.notCommitted.id))
                        .padding(.bottom, 4)
                }
                .contentShape(Rectangle())
                .tapGesture(logID: Log.notCommitted.id, selectionLogID: $selectionLogID, subSelectionLogID: $subSelectionLogID)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isSelected(Log.notCommitted.id) ? [.isSelected] : [])
            }

            ForEach(commits) { positioned in
                if let folder {
                    row(positioned, rowWidth: rowWidth)
                        .commitContextMenu(
                            folder: folder, commit: positioned.commit, logStore: logStore,
                            isRefresh: $isRefresh, showing: $showing, bindingError: $error
                        )
                } else {
                    row(positioned, rowWidth: rowWidth)
                }
            }
        }
        .frame(width: rowWidth, alignment: .leading)
        .padding(.horizontal, 8)
        .errorSheet($error)
    }

    private func row(_ positioned: PositionedCommit, rowWidth: CGFloat) -> some View {
        let selected = isSelected(positioned.id)
        let textLeading = CommitGraphStyle.textLeading(for: positioned)
        let textWidth = max(220, viewportWidth - 16 - textLeading - 10)
        return HStack(alignment: .top, spacing: 0) {
            CommitGraphLaneView(positioned: positioned, isSelected: selected,
                                connectsWorkingTree: positioned.row == 0 && notCommitted?.isEmpty == false)
                .frame(width: textLeading, height: CommitGraphStyle.rowHeight)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(positioned.commit.title)
                    .font(.callout)
                    .fontWeight(selected ? .medium : .regular)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text(positioned.id.prefix(7))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Text(positioned.commit.author)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(Text(verbatim: "\(positioned.commit.author) <\(positioned.commit.authorEmail)>"))
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Text(positioned.commit.authorDateRelative)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .help(positioned.commit.authorDateDisplay)
                    }
                    if let name = worktreeVisibility.decorations(positioned.commit.branches).first {
                        Label(name, systemImage: "arrow.triangle.branch")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(CommitGraphStyle.color(index: positioned.colorIndex))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(-1)
                    }
                }
            }
            .frame(width: textWidth, alignment: .leading)
            .padding(.top, CommitGraphStyle.titleTop)
            Spacer(minLength: 10)
        }
        .frame(width: rowWidth, height: CommitGraphStyle.rowHeight)
        .background(selectionBackground(for: positioned.id), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .tapGesture(logID: positioned.id, selectionLogID: $selectionLogID, subSelectionLogID: $subSelectionLogID)
        .help(positioned.commit.title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func isSelected(_ id: String) -> Bool {
        id == selectionLogID || id == subSelectionLogID
    }

    private func selectionBackground(for id: String) -> Color {
        guard isSelected(id) else { return .clear }
        return appearsActive ? Color.accentColor.opacity(0.12) : Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.5)
    }

}

enum CommitGraphStyle {
    static let rowHeight: CGFloat = 56
    static let laneSpacing: CGFloat = 18
    static let leadingInset: CGFloat = 16
    static let lineWidth: CGFloat = 1.8
    static let nodeY: CGFloat = 16
    static let titleTop: CGFloat = 8
    static let textGap: CGFloat = 18

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

    static func y(_ position: CommitGraphSegment.Position) -> CGFloat {
        switch position {
        case .top: 0
        case .node: nodeY
        case .bottom: rowHeight
        case .boundary: rowHeight - 8
        }
    }

    static func path(for segment: CommitGraphSegment) -> Path {
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
    var connectsWorkingTree = false

    var body: some View {
        Canvas { context, _ in
            let nodeX = CommitGraphStyle.x(column: positioned.column)
            // Associate every label with its commit node, including single-lane rows.
            let guide = Path { path in
                path.move(to: CGPoint(x: nodeX + 9, y: CommitGraphStyle.nodeY))
                path.addLine(to: CGPoint(x: CommitGraphStyle.textLeading(for: positioned) - 3,
                                        y: CommitGraphStyle.nodeY))
            }
            context.stroke(guide, with: .color(CommitGraphStyle.color(index: positioned.colorIndex).opacity(isSelected ? 0.6 : 0.35)),
                           style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 3]))
            if connectsWorkingTree {
                let connector = CommitGraphSegment(fromColumn: positioned.column, toColumn: positioned.column,
                                                   start: .top, end: .node, colorIndex: positioned.colorIndex)
                context.stroke(CommitGraphStyle.path(for: connector), with: .color(.secondary.opacity(0.5)),
                               style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
            for segment in positioned.segments {
                let color = CommitGraphStyle.color(index: segment.colorIndex)
                context.stroke(CommitGraphStyle.path(for: segment),
                               with: .color(color.opacity(segment.isBoundary ? 0.45 : 0.8)),
                               style: StrokeStyle(lineWidth: CommitGraphStyle.lineWidth,
                                                  lineCap: .round, lineJoin: .round,
                                                  dash: segment.isBoundary ? [2, 3] : []))
            }
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
        notCommitted: .constant(NotCommitted(diff: "hi", diffCached: "hello", status: .init(untrackedFiles: [], unmergedFiles: []))),
        selectionLogID: $selectionLogID,
        subSelectionLogID: $subSelectionLogID,
        logStore: logStore,
        showing: $showing,
        isRefresh: $isRefresh,
        commits: CommitGraph().positionedCommits(sampleCommits)
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
        notCommitted: .constant(NotCommitted(diff: "", diffCached: "", status: .init(untrackedFiles: [], unmergedFiles: []))),
        selectionLogID: $selectionLogID,
        subSelectionLogID: $subSelectionLogID,
        logStore: logStore,
        showing: $showing,
        isRefresh: $isRefresh,
        commits: CommitGraph().positionedCommits(sampleCommits2)
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
        notCommitted: .constant(NotCommitted(diff: "", diffCached: "", status: .init(untrackedFiles: [], unmergedFiles: []))),
        selectionLogID: $selectionLogID,
        subSelectionLogID: $subSelectionLogID,
        logStore: logStore,
        showing: $showing,
        isRefresh: $isRefresh,
        commits: CommitGraph().positionedCommits(sampleCommitsInSearch)
    )
    .environment(\.folder, URL(string: "file:///tmp/FoldGit/"))
        .background(Color(NSColor.textBackgroundColor))
        .frame(width: 400, height: 600)
}

