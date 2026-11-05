import FoldGitCore
import SwiftUI

struct BranchesView: View {
    @AppStorage(PreferenceKey.disableCommitOperations.rawValue) private var disableCommitOperations = false
    @Environment(WorktreeStore.self) private var worktrees
    @AppStorage(PreferenceKey.showWorktreeInformation.rawValue)
    private var globalShowWorktreeInformation = PreferenceDefaults.showWorktreeInformation
    @AppStorage(PreferenceKey.repositoryWorktreeVisibility.rawValue)
    private var worktreePreferencesData = PreferenceDefaults.repositoryWorktreeVisibility
    private var showWorktreeInformation: Bool {
        worktrees.showsInformation(for: folder.url, global: globalShowWorktreeInformation,
                                  preferences: RepositoryWorktreePreferences.decode(worktreePreferencesData))
    }
    var folder: WorkspaceEntry
    var branch: Branch?
    var onSelect: (Branch) -> Void
    var onSelectRemote: (Branch) -> Void
    var onSelectMergeInto: (Branch) -> Void
    var onSelectNewBranchFrom: (Branch) -> Void
    var onSelectRenameBranch: ((Branch) -> Void)?
    @State private var localBranches: [Branch] = []
    @State private var remoteBranches: [Branch] = []
    @State private var error: Error?
    @State private var filterText = ""
    @State private var isFetching = false
    @State private var isLoading = true
    @State private var isRemoteExpanded = false
    @State private var listFocusRequest = 0
    @State private var deleteCandidate: BranchDeletion?
    @State private var forceDeleteCandidate: BranchDeletion?
    @State private var isDeleting = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $filterText)
                    .onKeyPress(.downArrow) {
                        listFocusRequest += 1
                        return .handled
                    }
                    .onSubmit { listFocusRequest += 1 }
                if isFetching {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task {
                            isFetching = true
                            defer { isFetching = false }
                            do {
                                try await RemoteUpdateService.shared.execute(GitFetch(directory: folder.url))
                                AutoFetchScheduler.shared.recordFetchSuccess(for: folder.url)
                                try await loadBranches()
                            } catch {
                                self.error = OperationFailure("Fetch", error)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.down")
                    }
                    .help("Fetch")
                    .disabled(isLoading)
                }
            }
            .padding()
            Divider()
            BranchListContentView(
                localBranches: localBranches,
                remoteBranches: remoteBranches,
                filterText: filterText,
                isRemoteExpanded: $isRemoteExpanded,
                focusRequest: listFocusRequest,
                onSelect: onSelect,
                onSelectRemote: onSelectRemote,
                visibility: worktrees.visibility(for: folder.url, showInformation: showWorktreeInformation, currentBranch: branch?.name),
                worktreeBranches: worktrees.list(for: folder.url).reduce(into: [String: GitWorktree]()) { result, tree in
                    if let name = tree.branch, tree.id != folder.identity { result[name] = tree }
                }
            ) { item, isRemote in
                branchContextMenu(item, isRemote: isRemote)
            }
            .overlay {
                if isLoading || isDeleting {
                    ProgressView()
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .confirmationDialog("Delete Branch", isPresented: Binding(
            get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }
        ), titleVisibility: .visible, presenting: deleteCandidate) { candidate in
            Button("Delete", role: .destructive) { delete(candidate) }
            Button("Cancel", role: .cancel) {}
        } message: { candidate in
            if candidate.isRemote {
                Text("The remote-tracking branch \"\(candidate.branch.name)\" will be removed from this repository. The branch on the remote is not changed.")
            } else {
                Text("The branch \"\(candidate.branch.name)\" will be deleted.")
            }
        }
        .confirmationDialog("Force Delete Branch", isPresented: Binding(
            get: { forceDeleteCandidate != nil }, set: { if !$0 { forceDeleteCandidate = nil } }
        ), titleVisibility: .visible, presenting: forceDeleteCandidate) { candidate in
            Button("Force Delete", role: .destructive) { delete(candidate, force: true) }
            Button("Cancel", role: .cancel) {}
        } message: { candidate in
            Text("The branch \"\(candidate.branch.name)\" is not fully merged. Commits that only this branch contains will no longer be reachable.")
        }
        .task(id: branch) {
            isLoading = true
            defer { isLoading = false }
            do {
                try await loadBranches()
            } catch {
                guard !Task.isCancelled else { return }
                self.error = OperationFailure("Load Branches", error)
            }
        }
        .errorSheet($error, operation: "Load Branches")
    }

    @ViewBuilder
    private func branchContextMenu(_ item: Branch, isRemote: Bool) -> some View {
        if showWorktreeInformation && !isRemote, let tree = worktrees.destination(for: item.name, in: folder.url) {
            Button("Open Worktree", systemImage: "square.stack.3d.up") { onSelect(item) }
                .disabled(tree.isPrunable)
            Divider()
        }
        if !disableCommitOperations, let currentBranch = branch, isRemote || !item.isCurrent {
            Button("Merge into \"\(currentBranch.name)\"") {
                onSelectMergeInto(item)
            }
        }
        Button("New Branch from \"\(item.name)\"") {
            onSelectNewBranchFrom(item)
        }
        Button("Copy \"\(item.name)\"") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(item.name, forType: .string)
        }
        if !isRemote && !item.isDetached && worktrees.destination(for: item.name, in: folder.url) == nil {
            Button("Rename") {
                onSelectRenameBranch?(item)
            }
        }
        if isRemote || (!item.isCurrent && worktrees.destination(for: item.name, in: folder.url) == nil) {
            Button("Delete") {
                deleteCandidate = BranchDeletion(branch: item, isRemote: isRemote)
            }
            .disabled(isDeleting)
        }
    }

    private func delete(_ candidate: BranchDeletion, force: Bool = false) {
        guard !isDeleting else { return }
        isDeleting = true
        Task {
            defer { isDeleting = false }
            do {
                if force {
                    try await GitRuntime.run(GitBranchForceDelete(directory: folder.url, branchName: candidate.branch.name))
                } else {
                    try await GitRuntime.run(GitBranchDelete(directory: folder.url, isRemote: candidate.isRemote, branchName: candidate.branch.name))
                }
                try await loadBranches()
            } catch {
                // Git refuses unmerged branches; offer the explicit force delete instead of the raw message.
                if !force, !candidate.isRemote, GitBranchForceDelete.isUnmergedRefusal(error.localizedDescription) {
                    forceDeleteCandidate = candidate
                } else {
                    self.error = OperationFailure("Delete Branch", error)
                }
            }
        }
    }

    private func loadBranches() async throws {
        try await worktrees.refresh(folder.url)
        let local = try await GitRuntime.run(GitBranch(directory: folder.url))
        let remote = try await GitRuntime.run(GitBranch(directory: folder.url, isRemote: true))
        try Task.checkCancellation()
        localBranches = local.currentFirst
        remoteBranches = remote
    }
}

struct BranchDeletion: Identifiable {
    let branch: Branch
    let isRemote: Bool
    var id: String { (isRemote ? "remote:" : "local:") + branch.name }
}

struct BranchListContentView<ContextMenu: View>: View {
    let localBranches: [Branch]
    let remoteBranches: [Branch]
    var filterText: String
    @Binding var isRemoteExpanded: Bool
    /// Each change moves keyboard focus into the list and selects a row, for example from the filter field.
    var focusRequest = 0
    var onSelect: (Branch) -> Void
    var onSelectRemote: (Branch) -> Void
    var visibility = WorktreeVisibility()
    var worktreeBranches: [String: GitWorktree] = [:]
    @ViewBuilder var contextMenu: (Branch, Bool) -> ContextMenu
    @State private var selection: String?
    @FocusState private var isListFocused: Bool

    private static func tag(_ item: Branch, isRemote: Bool) -> String { (isRemote ? "remote:" : "local:") + item.name }

    /// Rows in display order, skipping collapsed remote branches, for keyboard movement.
    private var visibleRows: [(branch: Branch, isRemote: Bool)] {
        filteredLocal.map { ($0, false) } + (isRemoteExpanded ? filteredRemote.map { ($0, true) } : [])
    }

    private func row(for tag: String) -> (branch: Branch, isRemote: Bool)? {
        visibleRows.first { Self.tag($0.branch, isRemote: $0.isRemote) == tag }
    }

    private func activate(_ item: Branch, isRemote: Bool) {
        if isRemote {
            onSelectRemote(item)
        } else if !item.isCurrent, worktreeBranches[item.name]?.isPrunable != true {
            onSelect(item)
        }
    }

    private var filteredLocal: [Branch] {
        visibility.branches(localBranches.currentFirst).filter { filterText.isEmpty || $0.name.localizedCaseInsensitiveContains(filterText) }
    }

    private var filteredRemote: [Branch] {
        remoteBranches.filter { filterText.isEmpty || $0.name.localizedCaseInsensitiveContains(filterText) }
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(filteredLocal) { item in
                    branchButton(item, isRemote: false)
                }
                if filteredLocal.isEmpty {
                    Text(filterText.isEmpty ? String(localized: "No Branches") : String(localized: "No Results"))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Local Branches", image: "git.branch")
            }
            .listSectionSeparator(.hidden)
            Section {
                DisclosureGroup(isExpanded: $isRemoteExpanded) {
                    ForEach(filteredRemote) { item in
                        branchButton(item, isRemote: true)
                    }
                    if filteredRemote.isEmpty {
                        Text(filterText.isEmpty ? String(localized: "No Branches") : String(localized: "No Results"))
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    HStack {
                        Label("Remote Branches", systemImage: "cloud")
                        Spacer()
                        Text(filteredRemote.count, format: .number)
                            .monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("remoteBranchesDisclosure")
                .listRowSeparator(.hidden)
            }
            .listSectionSeparator(.hidden)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .focused($isListFocused)
        // Return and double-click check out the selected branch; a single click still checks out at once.
        .contextMenu(forSelectionType: String.self) { tags in
            if let tag = tags.first, let row = row(for: tag) { contextMenu(row.branch, row.isRemote) }
        } primaryAction: { tags in
            if let tag = tags.first, let row = row(for: tag) { activate(row.branch, isRemote: row.isRemote) }
        }
        .onChange(of: filterText) { _, value in
            isRemoteExpanded = !value.isEmpty
        }
        .onChange(of: focusRequest) {
            isListFocused = true
            if selection.flatMap(row(for:)) == nil {
                selection = visibleRows.first.map { Self.tag($0.branch, isRemote: $0.isRemote) }
            }
        }
    }

    private func branchButton(_ item: Branch, isRemote: Bool) -> some View {
        let isPrunable = !isRemote && worktreeBranches[item.name]?.isPrunable == true
        return BranchRowLabel(name: item.name, isCurrent: !isRemote && item.isCurrent, isRemote: isRemote,
                              worktree: isRemote || !visibility.showInformation ? nil : worktreeBranches[item.name])
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(!isRemote && item.isCurrent ? Color.accentColor.opacity(0.1) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                selection = Self.tag(item, isRemote: isRemote)
                activate(item, isRemote: isRemote)
            })
            .opacity(isPrunable ? 0.5 : 1)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { activate(item, isRemote: isRemote) }
            .tag(Self.tag(item, isRemote: isRemote))
            .listRowSeparator(.hidden)
    }
}

struct BranchRowLabel: View {
    let name: String
    var isCurrent = false
    var isRemote = false
    var worktree: GitWorktree?

    var body: some View {
        HStack(spacing: 8) {
            (isCurrent ? Image(systemName: "checkmark.circle.fill") : isRemote ? Image(systemName: "cloud") : .gitBranch)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            Text(name)
                .fontWeight(isCurrent ? .semibold : .regular)
                .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let worktree {
                WorktreeIndicator(path: worktree.url.path)
            }
            if isCurrent {
                Text("Current")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .fixedSize()
            }
        }
        .help(worktree?.url.path ?? name)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    BranchesView(
        folder: .init(url: URL(fileURLWithPath: "/tmp")),
        onSelect: { _ in },
        onSelectRemote: { _ in },
        onSelectMergeInto: { _ in },
        onSelectNewBranchFrom: { _ in },
        onSelectRenameBranch: { _ in }
    )
    .environment(WorktreeStore())
}
