import FoldGitCore
import SwiftUI

struct BranchesView: View {
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $filterText)
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
                                try await loadBranches()
                            } catch {
                                self.error = error
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
                if isLoading {
                    ProgressView()
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .task(id: branch) {
            isLoading = true
            defer { isLoading = false }
            do {
                try await loadBranches()
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error
            }
        }
        .errorSheet($error)
    }

    @ViewBuilder
    private func branchContextMenu(_ item: Branch, isRemote: Bool) -> some View {
        if showWorktreeInformation && !isRemote, let tree = worktrees.destination(for: item.name, in: folder.url) {
            Button("Open Worktree", systemImage: "square.stack.3d.up") { onSelect(item) }
                .disabled(tree.isPrunable)
            Divider()
        }
        if let currentBranch = branch, isRemote || !item.isCurrent {
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
                Task {
                    do {
                        try await GitRuntime.run(GitBranchDelete(directory: folder.url, isRemote: isRemote, branchName: item.name))
                        try await loadBranches()
                    } catch {
                        self.error = error
                    }
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

struct BranchListContentView<ContextMenu: View>: View {
    let localBranches: [Branch]
    let remoteBranches: [Branch]
    var filterText: String
    @Binding var isRemoteExpanded: Bool
    var onSelect: (Branch) -> Void
    var onSelectRemote: (Branch) -> Void
    var visibility = WorktreeVisibility()
    var worktreeBranches: [String: GitWorktree] = [:]
    @ViewBuilder var contextMenu: (Branch, Bool) -> ContextMenu

    private var filteredLocal: [Branch] {
        visibility.branches(localBranches.currentFirst).filter { filterText.isEmpty || $0.name.localizedCaseInsensitiveContains(filterText) }
    }

    private var filteredRemote: [Branch] {
        remoteBranches.filter { filterText.isEmpty || $0.name.localizedCaseInsensitiveContains(filterText) }
    }

    var body: some View {
        List {
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
        .onChange(of: filterText) { _, value in
            isRemoteExpanded = !value.isEmpty
        }
    }

    private func branchButton(_ item: Branch, isRemote: Bool) -> some View {
        Button {
            if isRemote {
                onSelectRemote(item)
            } else if !item.isCurrent {
                onSelect(item)
            }
        } label: {
            BranchRowLabel(name: item.name, isCurrent: !isRemote && item.isCurrent, isRemote: isRemote,
                           worktree: isRemote || !visibility.showInformation ? nil : worktreeBranches[item.name])
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(!isRemote && item.isCurrent ? Color.accentColor.opacity(0.1) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isRemote && worktreeBranches[item.name]?.isPrunable == true)
        .listRowSeparator(.hidden)
        .contextMenu { contextMenu(item, isRemote) }
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
