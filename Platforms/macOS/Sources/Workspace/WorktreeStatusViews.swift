import FoldGitCore
import SwiftUI

/// One identity icon carries the most important state; quantities stay in its tooltip.
enum WorktreeVisualState: Equatable {
    case unknown, clean, modified, integrated, operating, conflicted

    init(status: WorktreeStatus?, isMain: Bool, isOnTrunk: Bool) {
        guard let status else { self = .unknown; return }
        if status.changes.conflicted > 0 { self = .conflicted }
        else if status.operation != nil { self = .operating }
        else if !status.changes.isClean { self = .modified }
        else if !isMain && !isOnTrunk && status.trunk?.hasMergedWork == true { self = .integrated }
        else { self = .clean }
    }

    var color: Color {
        switch self {
        case .unknown, .clean: .secondary
        case .modified: .orange
        case .integrated: .green
        case .operating: .blue
        case .conflicted: .red
        }
    }

    var badge: String? {
        switch self {
        case .unknown, .clean: nil
        case .modified: "circle.fill"
        case .integrated: "checkmark.circle.fill"
        case .operating: "arrow.triangle.2.circlepath.circle.fill"
        case .conflicted: "exclamationmark.circle.fill"
        }
    }
}

/// Reads its own status entry, so a change in one worktree redraws only that worktree's icon.
/// The base icon keeps the caller's color and selection style; the state is carried by the badge alone.
struct WorktreeStatusIcon: View {
    let url: URL
    let isMain: Bool
    let name: String
    var symbol: String?
    var style = AnyShapeStyle(.secondary)
    @Environment(WorktreeStore.self) private var worktrees

    var body: some View {
        let entry = worktrees.statuses.entry(for: url)
        let state = WorktreeVisualState(status: entry.status, isMain: isMain, isOnTrunk: entry.isOnTrunk)
        let details = WorktreeStatusText.details(status: entry.status, isMain: isMain, isOnTrunk: entry.isOnTrunk,
                                                name: name, failed: entry.failed)
        Image(systemName: symbol ?? (isMain ? "book.closed" : "square.stack.3d.up"))
            .foregroundStyle(style)
            .overlay(alignment: .bottomTrailing) {
                if let badge = state.badge {
                    Image(systemName: badge)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(state == .modified ? state.color : .white, state.color)
                        .font(.system(size: 8, weight: .semibold))
                        .background(.background, in: Circle())
                        .offset(x: 4, y: 3)
                        .accessibilityHidden(true)
                }
            }
            .immediateHelp(details)
            .accessibilityLabel(Text(verbatim: details.title))
            .accessibilityValue(Text(verbatim: details.text))
    }
}

/// One labeled row per fact, shared by the sidebar tooltip and the worktree management sheet.
/// Every row names what it measures, including the reference it is compared with.
enum WorktreeStatusText {
    static func details(status: WorktreeStatus?, isMain: Bool, isOnTrunk: Bool,
                        name: String, failed: Bool = false) -> ImmediateHelpDetails {
        let title = (isMain ? String(localized: "Main Worktree") : String(localized: "Linked Worktree")) + " · " + name
        guard let status else {
            return ImmediateHelpDetails(title: title,
                summary: failed ? String(localized: "Worktree Status Unavailable") : String(localized: "Reading Worktree Status"),
                sections: [])
        }
        let state: String
        if status.changes.conflicted > 0 { state = String(localized: "Conflicted") }
        else if let operation = status.operation { state = self.title(for: operation) }
        else if !status.changes.isClean { state = String(localized: "Uncommitted Changes") }
        else { state = String(localized: "Clean Worktree") }
        let counts = status.changes
        let changes: [ImmediateHelpDetails.Row] = [
            (String(localized: "Staged Changes"), counts.staged),
            (String(localized: "Unstaged Changes"), counts.unstaged),
            (String(localized: "Untracked Files"), counts.untracked),
            (String(localized: "Conflicted"), counts.conflicted),
        ].filter { $0.1 > 0 }.map { label, count in
            .init(label: label, value: String(localized: "\(count) items"))
        }
        var sections: [ImmediateHelpDetails.Section] = [
            .init(rows: [.init(label: String(localized: "Working Tree"), value: state)] + changes),
        ]
        if isMain || isOnTrunk {
            if let upstream = status.upstream, let reference = status.working.upstreamReference {
                let rows = divergenceRows(ahead: upstream.ahead, behind: upstream.behind, reference: reference)
                if !rows.isEmpty { sections.append(.init(rows: rows)) }
            }
        } else if let trunk = status.trunk {
            let merge = integration(trunk).map { [ImmediateHelpDetails.Row(label: String(localized: "Merge Status"), value: $0)] } ?? []
            let rows = merge + divergenceRows(ahead: trunk.ahead, behind: trunk.behind, reference: trunk.reference)
            if !rows.isEmpty { sections.append(.init(rows: rows)) }
        }
        return ImmediateHelpDetails(title: title, summary: "", sections: sections)
    }

    private static func divergenceRows(ahead: Int, behind: Int, reference: String) -> [ImmediateHelpDetails.Row] {
        [(String(localized: "Ahead of \(reference)"), ahead), (String(localized: "Behind \(reference)"), behind)]
            .filter { $0.1 > 0 }.map { label, count in
                .init(label: label, value: String(localized: "\(count) commits"))
            }
    }

    static func integration(_ trunk: TrunkComparison) -> String? {
        // Name the reference that holds the work: merged into local main but not pushed reads "main", not "origin/main".
        let target = trunk.integratedInto ?? trunk.reference
        if trunk.isUnstarted { return String(localized: "No commits since this worktree was created") }
        return switch trunk.integration {
        case .ancestor: String(localized: "Merged into \(target)")
        case .contentMerged: String(localized: "Changes already in \(target) (squash or rebase merge)")
        case .notIntegrated: String(localized: "Not merged into \(trunk.reference)")
        case .unknown: nil
        }
    }

    static func title(for operation: GitPendingOperation) -> String {
        switch operation {
        case .merge: String(localized: "Merge in Progress")
        case .rebase: String(localized: "Rebase in Progress")
        case .cherryPick: String(localized: "Cherry-Pick in Progress")
        case .revert: String(localized: "Revert in Progress")
        case .bisect: String(localized: "Bisect in Progress")
        }
    }
}
