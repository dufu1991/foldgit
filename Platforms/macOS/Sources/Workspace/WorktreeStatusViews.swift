import FoldGitCore
import SwiftUI

/// At most two compact marks for a sidebar row; the full status is in the tooltip.
struct WorktreeStatusBadge: View {
    let status: WorktreeStatus
    var isOnTrunk = false

    var body: some View {
        HStack(spacing: 5) {
            if status.operation != nil || status.changes.conflicted > 0 {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else if status.changes.files > 0 {
                Text(verbatim: "● \(status.changes.files)").foregroundStyle(.orange)
            }
            if status.canBeCleanedUp && !isOnTrunk {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if let arrows = WorktreeStatusText.arrows(for: status, isOnTrunk: isOnTrunk) {
                Text(verbatim: arrows).foregroundStyle(.secondary)
            }
        }
        .font(.caption2.monospacedDigit())
        .fixedSize()
        .help(WorktreeStatusText.lines(for: status, isOnTrunk: isOnTrunk).joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Worktree Status"))
        .accessibilityValue(Text(verbatim: WorktreeStatusText.lines(for: status, isOnTrunk: isOnTrunk).joined(separator: ", ")))
    }
}

/// One line per fact, shared by the sidebar tooltip and the worktree management sheet.
enum WorktreeStatusText {
    static func arrows(for status: WorktreeStatus, isOnTrunk: Bool) -> String? {
        let counts: (ahead: Int, behind: Int)?
        if isOnTrunk {
            counts = status.upstream.map { ($0.ahead, $0.behind) }
        } else {
            counts = status.trunk.map { ($0.ahead, $0.behind) }
        }
        guard let counts, counts.ahead > 0 || counts.behind > 0 else { return nil }
        return [counts.ahead > 0 ? "↑\(counts.ahead)" : nil, counts.behind > 0 ? "↓\(counts.behind)" : nil]
            .compactMap { $0 }.joined(separator: " ")
    }

    static func lines(for status: WorktreeStatus, isOnTrunk: Bool) -> [String] {
        var lines: [String] = []
        if let operation = status.operation { lines.append(title(for: operation)) }
        let changes = status.changes
        if changes.isClean {
            lines.append(String(localized: "No Uncommitted Changes"))
        } else {
            lines.append(String(localized: "Changes: \(changes.staged) staged, \(changes.unstaged) unstaged, \(changes.untracked) untracked, \(changes.conflicted) conflicted"))
        }
        if let upstream = status.upstream {
            lines.append(String(localized: "Upstream: \(upstream.ahead) ahead, \(upstream.behind) behind"))
        }
        if let trunk = status.trunk, !isOnTrunk {
            lines.append(String(localized: "\(trunk.reference): \(trunk.ahead) ahead, \(trunk.behind) behind"))
            if let integration = integration(trunk) { lines.append(integration) }
        }
        return lines
    }

    static func integration(_ trunk: TrunkComparison) -> String? {
        // Name the reference that holds the work: merged into local main but not pushed reads "main", not "origin/main".
        let target = trunk.integratedInto ?? trunk.reference
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
        }
    }
}
