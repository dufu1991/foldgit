import AppKit
import FoldGitCore
import SwiftUI

struct WorktreeCompletionSheet: View {
    let onRemoved: (URL, URL) -> Void
    @State private var model: WorktreeCompletionModel
    @State private var isResolving = false
    @Environment(WorktreeStore.self) private var worktrees
    @Environment(\.openWorktree) private var openWorktree
    @Environment(\.dismiss) private var dismiss

    init(source: URL, onRemoved: @escaping (URL, URL) -> Void) {
        self.init(model: WorktreeCompletionModel(source: source), onRemoved: onRemoved)
    }

    init(model: WorktreeCompletionModel, onRemoved: @escaping (URL, URL) -> Void) {
        self.onRemoved = onRemoved
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Finish Worktree", systemImage: "checkmark.circle").font(.headline)
            HStack(spacing: 16) {
                Label("Review", systemImage: "doc.text.magnifyingglass")
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                Label("Merge", systemImage: "arrow.triangle.merge")
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                Label("Cleanup", systemImage: "checkmark.circle")
            }
            .font(.callout).foregroundStyle(.secondary)
            if model.phase == .review {
                review
            } else if model.phase == .conflicts, let plan = model.plan {
                Text(verbatim: plan.sourceBranch + " → " + plan.targetBranch)
                    .font(.callout).foregroundStyle(.secondary)
                MergeResolutionContent(directory: plan.target, onFinished: {
                    Task { await model.mergeFinished() }
                }, onAborted: { Task { await model.mergeAborted() } }, onBusyChanged: { isResolving = $0 })
            } else if let plan = model.plan {
                completed(plan)
            }
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if model.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button(model.phase == .done ? String(localized: "Done") : String(localized: "Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(model.isBusy || isResolving)
                if model.phase == .review {
                    Button("Merge into Target") { Task { await model.merge() } }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(model.plan == nil || model.isBusy)
                } else if model.phase == .merged {
                    Button("Finish Cleanup") { Task { await model.cleanup() } }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.isBusy)
                }
            }
        }
        .padding(24).frame(width: model.phase == .conflicts ? 760 : 600)
        .interactiveDismissDisabled(model.isBusy || isResolving)
        .task { if model.plan == nil { await model.load() } }
        .onChange(of: model.targetBranch) { old, new in
            if old != new && !model.isBusy { Task { await model.preview() } }
        }
        .onChange(of: model.sourceRemoved) {
            guard model.sourceRemoved, let plan = model.plan else { return }
            Task {
                try? await worktrees.refresh(plan.target)
                onRemoved(plan.source, plan.target)
            }
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Commit your work, merge into the target branch, then choose what to keep.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                LabeledContent("Source Worktree") {
                    Text(model.source.lastPathComponent).lineLimit(1).truncationMode(.middle).help(model.source.path)
                }
                Picker("Target Branch", selection: $model.targetBranch) {
                    if model.targets.isEmpty { Text("No Available Branches").tag("") }
                    ForEach(model.targets) { branch in Text(branch.name).tag(branch.name) }
                }
                .disabled(model.isBusy)
                if let plan = model.plan {
                    LabeledContent("Source Branch") { Text(plan.sourceBranch) }
                    LabeledContent("Commits to Merge") { Text(plan.commitCount, format: .number) }
                    LabeledContent("Target Worktree") {
                        Text(plan.target.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    }
                    if plan.switchesTargetBranch {
                        Text("The target directory will switch to the selected branch before merging.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("Open Source Worktree") { openWorktree(model.source); dismiss() }
                if let target = model.plan?.target ?? worktrees.list(for: model.source).first(where: { $0.branch == model.targetBranch })?.url {
                    Button("Open Target Worktree") { openWorktree(target); dismiss() }
                }
                Button("Refresh") { Task { await model.preview() } }.disabled(model.isBusy)
            }
        }
    }

    private func completed(_ plan: WorktreeCompletionPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(model.phase == .done ? String(localized: "Worktree Finished") : String(localized: "Merge Complete"),
                  systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            LabeledContent("Source Branch") { Text(plan.sourceBranch) }
            LabeledContent("Target Branch") { Text(plan.targetBranch) }
            Text("Changes are merged locally. Open the target worktree to review, test, and push.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.phase == .merged {
                GroupBox("Cleanup Options") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Remove Worktree Folder", isOn: $model.removeWorktree)
                            .disabled(model.sourceRemoved)
                        Toggle("Delete Local Source Branch", isOn: $model.deleteBranch)
                            .disabled(!model.removeWorktree || model.branchDeleted)
                        Text("Only a clean, unlocked worktree whose commits are merged can be removed. Remote branches are kept.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if model.sourceRemoved { Label("Worktree Folder Removed", systemImage: "checkmark") }
                        if model.branchDeleted { Label("Local Branch Deleted", systemImage: "checkmark") }
                    }
                    .toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                .disabled(model.isBusy)
                .onChange(of: model.removeWorktree) { if !model.removeWorktree { model.deleteBranch = false } }
            }
            Button("Open Target Worktree") { openWorktree(plan.target); dismiss() }
        }
    }
}
