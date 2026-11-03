import FoldGitCore
import SwiftUI

/// Lists linked worktrees whose commits are already on the trunk and removes the chosen ones without force.
struct WorktreeCleanupSheet: View {
    let onRemoved: (URL) -> Void
    @Environment(WorktreeStore.self) private var worktrees
    @Environment(\.dismiss) private var dismiss
    @State private var model: WorktreeCleanupModel

    init(repository: URL, onRemoved: @escaping (URL) -> Void) {
        self.onRemoved = onRemoved
        _model = State(initialValue: WorktreeCleanupModel(repository: repository))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Clean Up Merged Worktrees", systemImage: "trash").font(.headline)
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.load() } }
                    .labelStyle(.iconOnly).disabled(model.phase != .review)
            }
            Text("These linked worktrees have no uncommitted changes, and their commits are already on the trunk. Each one is checked again right before Git removes it, without force.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            content
            if let errorMessage = model.errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            if !model.candidates.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Delete Merged Local Branches", isOn: $model.deleteBranches)
                        .disabled(model.phase != .review)
                    Text("Branches merged by squash or rebase are kept, because deleting them requires force. Remote branches are never touched.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                if model.phase == .running || model.phase == .loading { ProgressView().controlSize(.small) }
                Spacer()
                if model.phase == .finished {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.phase == .running)
                    Button("Remove \(model.selectedCount) Worktrees") {
                        Task {
                            // Refresh before each callback, as manual removal does, so the sidebar never
                            // picks the removed worktree as a replacement selection.
                            await model.run { removed in
                                try? await worktrees.refresh(model.repository)
                                onRemoved(removed)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.phase != .review || model.selectedCount == 0)
                }
            }
        }
        .padding(24).frame(width: 620).interactiveDismissDisabled(model.phase == .running)
        .task { await model.load() }
    }

    @ViewBuilder private var content: some View {
        if model.phase == .loading && model.candidates.isEmpty {
            HStack { Spacer(); ProgressView(); Spacer() }.frame(minHeight: 120)
        } else if model.candidates.isEmpty {
            Text("No merged worktrees to clean up.")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if model.candidates.count > 1 {
                    let allSelected = model.selectedCount == model.candidates.count
                    Button(allSelected ? "Deselect All" : "Select All") {
                        model.selection = allSelected ? [] : Set(model.candidates.map(\.id))
                    }
                    .buttonStyle(.link).controlSize(.small).disabled(model.phase != .review)
                }
                List {
                    ForEach(model.candidates) { candidate in
                        row(candidate).padding(.vertical, 4)
                    }
                }
                .listStyle(.inset).frame(minHeight: 200, maxHeight: 360)
            }
        }
    }

    private func row(_ candidate: WorktreeCleanupCandidate) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: Binding(get: { model.selection.contains(candidate.id) }, set: { selected in
                if selected { model.selection.insert(candidate.id) } else { model.selection.remove(candidate.id) }
            })) { EmptyView() }
            .labelsHidden()
            .disabled(model.phase != .review)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(candidate.tree.url.lastPathComponent).fontWeight(.medium).lineLimit(1)
                    Text(candidate.tree.branch ?? String(localized: "Detached HEAD"))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if let integration = WorktreeStatusText.integration(candidate.trunk) {
                    Text(integration).font(.caption).foregroundStyle(.secondary)
                }
                if !candidate.ignoredEntries.isEmpty {
                    // Directories such as node_modules hold thousands of files; one entry per top-level item stays readable.
                    let groups = candidate.ignoredGroups.map { group in
                        group.files > 1 ? "\(group.name) (\(group.files.formatted()))" : group.name
                    }
                    Label("Ignored files will be deleted: \(groups.joined(separator: ", "))",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if candidate.isRecentlyActive(), let lastActivity = candidate.lastActivity {
                    let elapsed = RelativeDateTimeFormatter().localizedString(for: lastActivity, relativeTo: .now)
                    Label("Last activity \(elapsed)", systemImage: "clock")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text(candidate.tree.url.path).font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                if let outcome = model.outcomes[candidate.id] { outcomeLabel(outcome, branch: candidate.tree.branch) }
            }
        }
    }

    @ViewBuilder private func outcomeLabel(_ outcome: WorktreeCleanupModel.Outcome, branch name: String?) -> some View {
        switch outcome {
        case let .removed(branch):
            HStack(spacing: 8) {
                Label(Self.text(for: branch), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                // FoldGit never forces a delete; the command lets the user do it deliberately.
                if branch == .keptContentMerged, let name {
                    Button("Copy Delete Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("git branch -D \(name)", forType: .string)
                    }
                    .buttonStyle(.link).controlSize(.small)
                }
            }
        case let .failed(message):
            Label(message, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
        }
    }

    private static func text(for branch: WorktreeBranchOutcome) -> String {
        switch branch {
        case .deleted: String(localized: "Removed. The local branch was deleted.")
        case .notRequested, .keptDetached: String(localized: "Removed.")
        case .keptContentMerged: String(localized: "Removed. The branch was kept because it was merged by squash or rebase.")
        case .keptTrunk, .keptCheckedOut: String(localized: "Removed. The branch was kept because it is still in use.")
        case let .failed(message): String(localized: "Removed. The branch was kept: \(message)")
        }
    }
}
