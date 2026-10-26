import AppKit
import FoldGitCore
import SwiftUI

struct WorktreeSheetTarget: Identifiable {
    let url: URL
    var id: URL { url }
}

struct WorktreeIndicator: View {
    let path: String

    var body: some View {
        Image(systemName: "square.stack.3d.up")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(String(localized: "Linked Worktree") + "\n" + path)
            .accessibilityLabel(Text("Linked Worktree"))
    }
}

struct WorktreeCreateSheet: View {
    let repository: URL
    @Environment(WorktreeStore.self) private var worktrees
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWorktree) private var openWorktree
    @State private var parent: URL
    @State private var directoryName: String
    @State private var mode = WorktreeCreationMode.newBranch
    @State private var branchName = ""
    @State private var startPoint = "HEAD"
    @State private var existingBranch = ""
    @State private var branches: [Branch] = []
    @State private var isLoading = true
    @State private var isCreating = false
    @State private var errorMessage: String?
    @FocusState private var branchIsFocused: Bool

    init(repository: URL) {
        self.repository = repository
        _parent = State(initialValue: repository.deletingLastPathComponent())
        _directoryName = State(initialValue: repository.lastPathComponent + "-worktree")
    }

    private var availableBranches: [Branch] {
        let occupied = Set(worktrees.list(for: repository).compactMap(\.branch))
        return branches.filter { !$0.isDetached && !occupied.contains($0.name) }
    }
    private var destination: URL { parent.appendingPathComponent(directoryName) }
    private var canCreate: Bool {
        !isLoading && !isCreating && !directoryName.isEmpty && directoryName != "." && directoryName != ".."
            && !directoryName.contains("/") && !directoryName.contains("\0")
            && (mode == .existingBranch ? availableBranches.contains { $0.name == existingBranch }
                : !startPoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && (mode == .detached || !branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("New Worktree", systemImage: "square.stack.3d.up").font(.headline)
            Text("Work on another branch in a separate folder while keeping your current changes.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                Picker("Branch", selection: $mode) {
                    Text("New Branch").tag(WorktreeCreationMode.newBranch)
                    Text("Existing Branch").tag(WorktreeCreationMode.existingBranch)
                    Text("Detached HEAD").tag(WorktreeCreationMode.detached)
                }
                if mode == .existingBranch {
                    Picker("Existing Branch", selection: $existingBranch) {
                        if availableBranches.isEmpty { Text("No Available Branches").tag("") }
                        ForEach(availableBranches) { branch in Text(branch.name).tag(branch.name) }
                    }
                    Text("Branches already checked out in a worktree are unavailable.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    if mode == .newBranch {
                        TextField("New Branch Name", text: $branchName).focused($branchIsFocused)
                            .accessibilityIdentifier("worktreeBranchName")
                    }
                    TextField("Start Point", text: $startPoint)
                }
                LabeledContent("Save Location") {
                    HStack {
                        Text(parent.path).lineLimit(2).truncationMode(.middle)
                        Button("Choose", action: chooseParent)
                    }
                }
                TextField("Folder Name", text: $directoryName)
                    .accessibilityIdentifier("worktreeDirectoryName")
            }
            .textFieldStyle(.roundedBorder).disabled(isCreating)
            Text(destination.path).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            if let errorMessage { WorktreeErrorLabel(message: errorMessage) }
            HStack {
                if isCreating || isLoading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(isCreating)
                Button("Create", action: create).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(!canCreate)
            }
        }
        .padding(24).frame(width: 540).interactiveDismissDisabled(isCreating)
        .task {
            defer { isLoading = false }
            do {
                try await worktrees.refresh(repository)
                branches = try await GitRuntime.run(GitBranch(directory: worktrees.source(for: repository)))
                if let tree = worktrees.worktree(at: repository) { startPoint = tree.branch ?? tree.head ?? "HEAD" }
                existingBranch = availableBranches.first?.name ?? ""
                branchIsFocused = true
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = parent
        panel.begin { response in
            if response == .OK, let url = panel.url { parent = url }
        }
    }

    private func create() {
        guard canCreate else { return }
        let branch: WorktreeBranch = switch mode {
        case .newBranch: .new(name: branchName.trimmingCharacters(in: .whitespacesAndNewlines), startPoint: startPoint)
        case .existingBranch: .existing(existingBranch)
        case .detached: .detached(startPoint: startPoint)
        }
        isCreating = true
        errorMessage = nil
        Task {
            defer { isCreating = false }
            do {
                try await worktrees.execute(.add(destination: destination, branch: branch), in: repository)
                openWorktree(destination)
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

private enum WorktreeCreationMode: Hashable { case newBranch, existingBranch, detached }

struct WorktreeManagementSheet: View {
    @Environment(\.folder) private var currentDirectory
    let repository: URL
    let onRelocated: (URL, URL?) -> Void
    @Environment(WorktreeStore.self) private var worktrees
    @Environment(\.openWorktree) private var openWorktree
    @Environment(\.dismiss) private var dismiss
    @State private var showingCreate = false
    @State private var finishing: WorktreeSheetTarget?
    @State private var removing: GitWorktree?
    @State private var moving: GitWorktree?
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var dirty: [URL: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Manage Worktrees", systemImage: "square.stack.3d.up").font(.headline)
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } }
                    .labelStyle(.iconOnly).disabled(isBusy)
            }
            Text("Worktrees share repository history and branches. Each folder has its own files and staging area.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(worktrees.list(for: repository).filter { !$0.isBare }) { tree in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: tree.isMain ? "arrow.triangle.branch" : "square.stack.3d.up")
                                .foregroundStyle(.secondary)
                            Text(tree.url.lastPathComponent).fontWeight(.medium).lineLimit(1)
                            if tree.isMain { Text("Main Worktree").font(.caption).foregroundStyle(.secondary) }
                            if tree.isLocked { Image(systemName: "lock.fill").help(tree.lockReason ?? "") }
                            Spacer()
                            if tree.id == (currentDirectory ?? repository).standardizedFileURL.resolvingSymlinksInPath() {
                                Text("Current").font(.caption).foregroundStyle(.tint)
                            }
                        }
                        Text(tree.branch ?? String(localized: "Detached HEAD"))
                            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        Text(tree.url.path).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        if tree.isPrunable {
                            Label("Missing Worktree", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange).help(tree.pruneReason ?? "")
                        } else if let hasChanges = dirty[tree.id] {
                            Text(hasChanges ? String(localized: "Uncommitted Changes") : String(localized: "Clean Worktree"))
                                .font(.caption).foregroundStyle(hasChanges ? Color.orange : Color.secondary)
                        }
                        HStack {
                            Button("Open") { openWorktree(tree.url); dismiss() }.disabled(tree.isPrunable)
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([tree.url]) }
                                .disabled(tree.isPrunable)
                            Spacer()
                            if !tree.isMain {
                                Menu {
                                    if tree.branch != nil && !tree.isPrunable {
                                        Button("Finish Worktree", systemImage: "checkmark.circle") {
                                            finishing = WorktreeSheetTarget(url: tree.url)
                                        }
                                        Divider()
                                    }
                                    Button(tree.isLocked ? String(localized: "Unlock Worktree") : String(localized: "Lock Worktree"),
                                           systemImage: tree.isLocked ? "lock.open" : "lock") {
                                        perform(tree.isLocked ? .unlock(tree.url) : .lock(tree.url))
                                    }
                                    Button("Move Worktree", systemImage: "folder") { moving = tree }
                                        .disabled(tree.isLocked || tree.isPrunable)
                                    Divider()
                                    Button("Remove Worktree", systemImage: "trash", role: .destructive) { removing = tree }
                                        .disabled(tree.isLocked || tree.isPrunable)
                                } label: { Image(systemName: "ellipsis.circle") }
                                .menuIndicator(.hidden).fixedSize().help("Worktree Actions")
                            }
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 6)
                }
            }
            .listStyle(.inset).frame(minHeight: 240, maxHeight: 380).disabled(isBusy)
            if let errorMessage { WorktreeErrorLabel(message: errorMessage) }
            HStack {
                Button("New Worktree", systemImage: "plus") { showingCreate = true }
                if worktrees.list(for: repository).contains(where: \.isPrunable) {
                    Button("Prune Missing Worktrees") { perform(.prune) }
                }
                if isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .disabled(isBusy)
        }
        .padding(24).frame(width: 640).interactiveDismissDisabled(isBusy)
        .task { await reload() }
        .sheet(item: $finishing, onDismiss: { Task { await reload() } }) { target in
            WorktreeCompletionSheet(source: target.url) { source, _ in onRelocated(source, nil) }
        }
        .sheet(isPresented: $showingCreate) { WorktreeCreateSheet(repository: repository) }
        .sheet(item: $moving) { tree in
            WorktreeMoveSheet(tree: tree, repository: repository) { destination in
                onRelocated(tree.url, destination)
            }
        }
        .confirmationDialog("Remove Worktree?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { tree in
            Button("Remove Worktree", role: .destructive) {
                perform(.remove(tree.url), removed: tree.url)
            }
        } message: { tree in
            Text("This removes the folder at \(tree.url.path). The branch is kept. Git refuses removal if the worktree has uncommitted changes or untracked files.")
        }
    }

    private func reload() async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await worktrees.refresh(repository)
            dirty = [:]
            for tree in worktrees.list(for: repository) where !tree.isBare && !tree.isPrunable {
                let output = try await GitRuntime.run(arguments: ["git", "status", "--porcelain", "-z"], currentDirectoryURL: tree.url)
                dirty[tree.id] = !output.standardOutput.isEmpty
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func perform(_ operation: WorktreeOperation, removed: URL? = nil) {
        isBusy = true
        errorMessage = nil
        Task {
            do {
                let previous = worktrees.list(for: repository)
                try await worktrees.execute(operation, in: repository)
                if let removed { onRelocated(removed, nil) }
                if case .prune = operation {
                    let remaining = Set(worktrees.list(for: repository).map(\.id))
                    for tree in previous where !remaining.contains(tree.id) { onRelocated(tree.url, nil) }
                }
                await reload()
            } catch { errorMessage = error.localizedDescription }
            isBusy = false
        }
    }
}

private struct WorktreeMoveSheet: View {
    let tree: GitWorktree
    let repository: URL
    let onMoved: (URL) -> Void
    @Environment(WorktreeStore.self) private var worktrees
    @Environment(\.dismiss) private var dismiss
    @State private var destination: URL?
    @State private var isMoving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Move Worktree").font(.headline)
            Text(tree.url.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                if let destination {
                    Text(destination.path).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                } else { Text("Choose a new folder location.").foregroundStyle(.secondary) }
                Spacer()
                Button("Choose") {
                    let panel = NSSavePanel()
                    panel.title = String(localized: "Move Worktree")
                    panel.nameFieldStringValue = tree.url.lastPathComponent
                    panel.directoryURL = tree.url.deletingLastPathComponent()
                    panel.canCreateDirectories = true
                    panel.begin { response in
                        if response == .OK { destination = panel.url }
                    }
                }
            }
            .disabled(isMoving)
            if let errorMessage { WorktreeErrorLabel(message: errorMessage) }
            HStack {
                if isMoving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(isMoving)
                Button("Move") {
                    guard let destination else { return }
                    isMoving = true
                    errorMessage = nil
                    Task {
                        defer { isMoving = false }
                        do {
                            try await worktrees.execute(.move(tree.url, destination: destination), in: repository)
                            onMoved(destination)
                            dismiss()
                        } catch { errorMessage = error.localizedDescription }
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(destination == nil || destination == tree.url || isMoving)
            }
        }
        .padding(24).frame(width: 520).interactiveDismissDisabled(isMoving)
    }
}

private struct WorktreeErrorLabel: View {
    let message: String
    var body: some View {
        ScrollView {
            Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 90)
    }
}
