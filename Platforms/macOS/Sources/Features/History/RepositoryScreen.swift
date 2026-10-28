import AppKit
import FoldGitCore
import Foundation
import SwiftUI

struct RepositoryScreen: View {
    @Environment(WorktreeStore.self) private var worktrees
    @Environment(\.openWorktree) private var openWorktree
    @Environment(\.worktreeVisibility) private var worktreeVisibility
    var folder: WorkspaceEntry
    @Binding var selectionLog: Log?
    @Binding var subSelectionLogID: String?
    @Binding var isRefresh: Bool
    @State private var session = RepositorySession()
    private var logStore: HistoryStore { session.history }
    private var syncState: RemoteSyncState { session.remote }
    @State private var isLoading = false
    @State private var isFetching = false
    @State private var error: Error?
    @State private var showing = RepositoryPresentation()
    private var branch: Branch? { session.branch }
    @State private var selectionLogID: String?
    @State private var searchText = ""
    @State private var searchFocusRequest = UUID()
    @AppStorage(PreferenceKey.showCommitGraph.rawValue) private var showGraph = true
    @State private var showingSyncError = false

    var body: some View {
        @Bindable var session = session
        VStack(spacing: 0) {
            // Shares the toolbar edge with the detail column, whose scroll view draws its line there.
            Divider()
            HStack(spacing: 8) {
                NativeSearchField(text: $searchText, placeholder: String(localized: "Search Author, Email, or Message"),
                                  accessibilityIdentifier: "commitSearchField", focusRequest: searchFocusRequest) { text, composing in
                    logStore.search(text, isComposing: composing)
                }
                .frame(height: 26)
                if logStore.isSearching { ProgressView().controlSize(.small) }
                Menu {
                    Picker("History Scope", selection: Binding(get: { logStore.scope }, set: { scope in
                        Task { await logStore.setScope(scope) }
                    })) {
                        Text("Current Branch").tag(HistoryScope.currentBranch)
                        Text("All Commits").tag(HistoryScope.allCommits)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(logStore.scope == .currentBranch ? String(localized: "Current Branch") : String(localized: "All Commits"))
                }
                .fixedSize()
                .accessibilityIdentifier("historyScopeMenu")
                .help("History Scope")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            if let tracking = syncState.tracking, tracking.behind > 0 {
                HStack(spacing: 8) {
                    Text("Behind by \(tracking.behind) commits")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if logStore.isRevealingIncoming { ProgressView().controlSize(.small) }
                    Button("View Incoming Commits") {
                        searchText = ""
                        Task {
                            if let target = await logStore.revealIncoming() {
                                subSelectionLogID = nil
                                selectionLogID = target
                            }
                        }
                    }
                    .disabled(logStore.isRevealingIncoming)
                    .accessibilityIdentifier("viewIncomingCommitsButton")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
            }
            if showGraph {
                CommitGraphView(
                    logStore: session.history,
                    selectionLogID: $selectionLogID,
                    subSelectionLogID: $subSelectionLogID,
                    showing: $showing,
                    isRefresh: $isRefresh
                )
            } else {
                CommitLogView(
                    logStore: session.history,
                    selectionLogID: $selectionLogID,
                    subSelectionLogID: $subSelectionLogID,
                    showing: $showing,
                    isRefresh: $isRefresh,
                    error: $error
                )
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if session.mergeState?.isMerging == true {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Merge in Progress", systemImage: "arrow.triangle.merge").font(.callout.weight(.medium))
                    Button("Resolve Merge") { showing.mergeResolution = true }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
            }
        }
        .scrollEdgeEffectStyle(.hard, for: .vertical)
        .safeAreaBar(edge: .bottom, spacing: 0) {
            HStack(spacing: 0) {
                Spacer()
                countText()
                    .font(.callout)
                Spacer()
            }
            .overlay(alignment: .trailing, content: {
                Toggle(isOn: $showGraph) {
                    Label("Commit Graph", systemImage: "arrow.triangle.branch")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 20, height: 20)
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.horizontal)
                .help("Commit Graph")
                .accessibilityLabel(Text("Commit Graph"))
            })
            .frame(height: 40)
        }
        .overlay {
            if logStore.commits.isEmpty && !logStore.searchText.isEmpty && !logStore.isSearching {
                Text("No Results").foregroundStyle(.secondary)
            }
        }
        .background {
            Button("Search Commits") { searchFocusRequest = UUID() }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        .onDisappear { logStore.cancelSearch() }
        .task {
            await refreshModels(fetchRemote: true)
        }
        .onChange(of: logStore.logs()) { syncHistorySelection() }
        .onChange(of: logStore.isSearching) { syncHistorySelection() }
        .onChange(of: selectionLogID, {
            selectionLog = logStore.logs().first { $0.id == selectionLogID }
        })
        .onChange(of: selectionLog, {
            if selectionLog == nil {
                selectionLogID = nil
                subSelectionLogID = nil
            }
        })
        .onChange(of: isRefresh, { oldValue, newValue in
            if newValue {
                Task {
                    await refreshModels()
                    isRefresh = false
                }
            }
        })
        .onReceive(NotificationCenter.default.publisher(for: .repositoryMergeDidChange)) { _ in
            Task { await refreshModels() }
        }
        .sheet(isPresented: $showing.mergeResolution, onDismiss: {
            Task { await refreshModels() }
        }) { MergeResolutionSheet(directory: folder.url) }
        .errorSheet($error)
        .errorSheet($session.history.error)
        .sheet(item: $showing.createNewBranchFrom, content: { _ in
            CreateNewBranchSheet(folder: folder, showingCreateNewBranchFrom: $showing.createNewBranchFrom) {
                Task {
                    await refreshModels()
                }
            }
        })
        .sheet(item: $showing.renameBranch, onDismiss: {
            Task {
                await refreshModels()
            }
        }, content: { _ in
            RenameBranchSheet(folder: folder, showingRenameBranch: $showing.renameBranch)
        })
        .sheet(item: $showing.createNewTagAt, content: { _ in
            CreateNewTagSheet(folder: folder, showingCreateNewTagAt: $showing.createNewTagAt) {
                Task {
                    await refreshModels()
                }
            }
        })
        .sheet(item: $showing.amendCommitAt, content: { _ in
            AmendCommitSheet(folder: folder, showingAmendCommitAt: $showing.amendCommitAt) {
                Task {
                    await refreshModels()
                }
            }
        })
        .sheet(isPresented: $showing.stashChanged, content: {
            StashChangedView(folder: folder, showingStashChanged: $showing.stashChanged)
        })
        .sheet(isPresented: $showing.compareRevisions) {
            CompareRevisionsView(folder: folder)
        }
        .navigationTitle(branch?.name ?? folder.displayName)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                branchesButton()
                    .disabled(isLoading)
            }
            if isLoading {
                ToolbarItem(placement: .primaryAction) {
                    ProgressView()
                        .scaleEffect(x: 0.5, y: 0.5, anchor: .center)
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                if syncState.syncError != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingSyncError.toggle()
                        } label: {
                            Label {
                                Text("Sync Error")
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                            }
                        }
                        .help("Sync Error")
                        .popover(isPresented: $showingSyncError) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Sync Error")
                                    .font(.headline)
                                ScrollView {
                                    Text(syncState.syncError ?? "")
                                        .textSelection(.enabled)
                                }
                            }
                            .padding()
                            .frame(width: 360, height: 160)
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    fetchButton()
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(id: "repositoryPull", placement: .primaryAction) {
                    pullButton()
                        .disabled(isFetching)
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(id: "repositoryPush", placement: .primaryAction) {
                    pushButton()
                        .disabled(isFetching)
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    addBranchButton()
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    tagButton()
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    stashButton()
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    compareButton()
                }
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                OpenInMenu(directory: folder.url, onError: { error = $0 })
            }
        }
        .onChange(of: showing.stashChanged) { _, new in
            if !new {
                Task {
                    await refreshModels()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willBecomeActiveNotification)) { _ in
            Task {
                await refreshModels()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .projectAutoFetchDidFinish)) { notification in
            guard let event = notification.object as? AutoFetchEvent,
                  AutoFetchScheduler.key(for: event.directory) == AutoFetchScheduler.key(for: folder.url) else { return }
            syncState.syncError = event.error
            if event.error == nil {
                Task { await refreshModels() }
            }
        }
    }

    private func syncHistorySelection() {
        guard !logStore.isSearching else { return }
        let logs = logStore.logs()
        if let subSelectionLogID, !logs.contains(where: { $0.id == subSelectionLogID }) {
            self.subSelectionLogID = nil
        }
        guard !logs.contains(where: { $0.id == selectionLogID }) else { return }
        subSelectionLogID = nil
        selectionLogID = logs.first?.id
        selectionLog = logs.first
    }

    /// Only opening the repository fetches; local operations refresh from local refs.
    private func refreshModels(fetchRemote: Bool = false) async {
        await session.refresh(in: folder.url, fetchRemote: fetchRemote)
        guard !Task.isCancelled else { return }
        if let error = session.error { self.error = error }
        if let selectionLog { self.selectionLog = logStore.logs().first { $0.id == selectionLog.id } }
    }

    fileprivate func branchesButton() -> some View {
        Button {
            showing.branches.toggle()
        } label: {
            Label {
                Text("Select Branch")
            } icon: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.trianglehead.branch")
                        .foregroundStyle(Color.accentColor)
                    Text(branch?.name ?? String(localized: "Branches"))
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 240, alignment: .leading)
                }
            }
        }
        .accessibilityValue(Text(branch?.name ?? String(localized: "Branches")))
        .help("Select Branch")
        .popover(isPresented: $showing.branches) {
            BranchesView(
                folder: folder,
                branch: branch,
                onSelect: { selected in
                    showing.branches = false
                    if worktreeVisibility.showInformation, let tree = worktrees.destination(for: selected.name, in: folder.url) {
                        openWorktree(tree.url)
                        return
                    }
                    Task {
                        do {
                            try await GitRuntime.run(GitSwitch(directory: folder.url, branchName: selected.name))
                        } catch {
                            self.error = error
                        }
                        await refreshModels()
                    }
                },
                onSelectRemote: { selected in
                    showing.branches = false
                    Task {
                        do {
                            try await GitRuntime.run(GitSwitch(directory: folder.url, branchName: selected.name, detach: true))
                        } catch {
                            self.error = error
                        }
                        await refreshModels()
                    }
                },
                onSelectMergeInto: { selected in
                    showing.branches = false
                    Task {
                        do {
                            try await GitRuntime.run(GitMerge(directory: folder.url, branchName: selected.name))
                        } catch {
                            let mergeState = try? await GitMergeState.read(in: folder.url)
                            if mergeState?.isMerging != true { self.error = error }
                        }
                        await refreshModels()
                        if session.mergeState?.isMerging == true { showing.mergeResolution = true }
                    }
                },
                onSelectNewBranchFrom: { from in
                    showing.branches = false
                    showing.createNewBranchFrom = from
                },
                onSelectRenameBranch: { old in
                    showing.branches = false
                    showing.renameBranch = old
                }
            )
            .frame(width: 360, height: 560)
        }
    }

    fileprivate func addBranchButton() -> some View {
        Button {
            showing.createNewBranchFrom = branch
        } label: {
            Label("Create New Branch", systemImage: "plus")
        }
        .help("Create New Branch")
    }

    fileprivate func tagButton() -> some View {
        Button {
            showing.tags.toggle()
        } label: {
            Label("Show Tags", systemImage: "tag")
        }
        .help("Show Tags")
        .popover(isPresented: $showing.tags) {
            TagsView(folder: folder, showingTags: $showing.tags)
        }
        .onChange(of: showing.tags) { _, isPresented in
            if !isPresented {
                Task { await refreshModels() }
            }
        }
    }

    fileprivate func stashButton() -> some View {
        Button {
            showing.stashChanged.toggle()
        } label: {
            Label("Show Stashed Changes", systemImage: "tray")
        }
        .help("Show Stashed Changes")
    }

    fileprivate func compareButton() -> some View {
        Button {
            showing.compareRevisions = true
        } label: {
            Label("Compare Branches or Tags", systemImage: "arrow.left.arrow.right")
        }
        .help("Compare Branches or Tags")
    }

    private func fetchButton() -> some View {
        Button {
            isFetching = true
            Task {
                defer { isFetching = false }
                do {
                    try await RemoteUpdateService.shared.execute(GitFetch(directory: folder.url))
                    syncState.syncError = nil
                    await refreshModels()
                } catch {
                    syncState.syncError = error.localizedDescription
                    self.error = error
                }
            }
        } label: {
            Label {
                Text("Fetch")
            } icon: {
                if isFetching {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .disabled(isFetching)
        .help("Fetch")
    }

    fileprivate func pullButton() -> some View {
        PullToolbarButton(count: pullBehindCount, toolTip: pullDescription, onPull: pullChanges)
    }

    private func pullChanges() {
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                guard let branch, let tracking = try await TrackingBranch.inspect(in: folder.url, branch: branch.name), tracking.upstream != nil else { return }
                try await RemoteUpdateService.shared.execute(GitPull(directory: folder.url, refspec: tracking.remoteBranch, remote: tracking.remote))
                syncState.shouldPull = false
                isLoading = false
                await refreshModels()
            } catch {
                isLoading = false
                self.error = error
            }
        }
    }

    private var pullDescription: String {
        if pullBehindCount > 0 {
            String(localized: "Pull") + " · " + String(localized: "Behind by \(pullBehindCount) commits")
        } else {
            String(localized: "Pull")
        }
    }

    private var pullBehindCount: Int {
        if syncState.shouldPull, let tracking = syncState.tracking {
            return tracking.behind
        }
        return 0
    }

    fileprivate func pushButton() -> some View {
        PushToolbarButton(count: pushAheadCount, onPush: pushChanges)
    }

    private var pushAheadCount: Int {
        if syncState.shouldPush, let tracking = syncState.tracking {
            return tracking.ahead
        }
        return 0
    }

    private func pushChanges() {
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                guard let branch, let tracking = try await TrackingBranch.inspect(in: folder.url, branch: branch.name) else { return }
                try await GitRuntime.run(GitPush(directory: folder.url, refspec: "HEAD:refs/heads/\(tracking.remoteBranch)", remote: tracking.remote, setUpstream: tracking.upstream == nil))
                syncState.shouldPush = false
                isLoading = false
                await refreshModels()
            } catch {
                isLoading = false
                self.error = error
            }
        }
    }

    fileprivate func countText() -> some View {
        if let count = logStore.totalCommitsCount {
            return Text("\(count) commits")
        } else {
            return Text("")
        }
    }
}

struct PullToolbarButton: View {
    let count: Int
    let toolTip: String
    let onPull: () -> Void

    var body: some View {
        Button(action: onPull) {
            Label("Pull", systemImage: "arrow.down")
        }
        .badge(count)
        .help(toolTip)
        .accessibilityLabel(Text(toolTip))
        .accessibilityIdentifier("pullChangesButton")
    }
}

struct PushToolbarButton: View {
    let count: Int
    let onPush: () -> Void

    var body: some View {
        Button(action: onPush) {
            Label("Push", systemImage: "arrow.up")
        }
        .badge(count)
        .help("Push")
        .accessibilityIdentifier("pushChangesButton")
    }
}

#Preview {
    @Previewable @State var selection: Log?
    @Previewable @State var subSelection: String?
    @Previewable @State var refresh = false
    RepositoryScreen(
        folder: .init(url: URL(string: "file:///tmp/FoldGit/")!),
        selectionLog: $selection,
        subSelectionLogID: $subSelection,
        isRefresh: $refresh
    )
    .environment(WorktreeStore())
}
