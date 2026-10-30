import AppKit
import FoldGitCore
import Foundation
import SwiftUI

struct RepositoryScreen: View {
    @Environment(WorktreeStore.self) private var worktrees
    @Environment(\.openWorktree) private var openWorktree
    @Environment(\.worktreeVisibility) private var worktreeVisibility
    @Environment(\.toggleCommandLog) private var toggleCommandLog
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
    @State private var checkoutConfirmation: Commit?
    @State private var revertConfirmation: Commit?
    /// Shared by the toolbar's Open in menu and the menu bar so applications are discovered once per repository.
    @State private var menuApplications = OpenInStore()
    private static let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")

    var body: some View {
        @Bindable var session = session
        VStack(spacing: 0) {
            // Shares the toolbar edge with the detail column, whose scroll view draws its line there.
            Divider()
            HStack(spacing: 8) {
                NativeSearchField(text: $searchText, placeholder: String(localized: "Search Commits"),
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
                    Button("Show") {
                        searchText = ""
                        Task {
                            if let target = await logStore.revealIncoming() {
                                subSelectionLogID = nil
                                selectionLogID = target
                            }
                        }
                    }
                    .help("View Incoming Commits")
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
                    Label("Merge in Progress", systemImage: "arrow.trianglehead.merge").font(.callout.weight(.medium))
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
                    Label("Commit Graph", systemImage: "arrow.trianglehead.branch")
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
        .focusedSceneValue(\.repositoryMenu, menuContext)
        .onDisappear { logStore.cancelSearch() }
        .task {
            await refreshModels(fetchRemote: true)
        }
        .loadsApplications(menuApplications, for: folder.url)
        .onChange(of: logStore.logs()) { syncHistorySelection() }
        .onChange(of: logStore.isSearching) { syncHistorySelection() }
        .onChange(of: logStore.error?.localizedDescription) { _, _ in
            if let error = logStore.error {
                self.error = OperationFailure("Commit History", error)
            }
        }
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
        .onReceive(NotificationCenter.default.publisher(for: .settingsDidRestoreDefaults)) { _ in
            Task { await logStore.setScope(.currentBranch) }
        }
        .sheet(isPresented: $showing.mergeResolution, onDismiss: {
            Task { await refreshModels() }
        }) { MergeResolutionSheet(directory: folder.url) }
        .sheet(isPresented: $showing.mergeBranch) {
            MergeBranchMenuSheet(directory: folder.url, currentBranch: branch?.name) { selected in
                showing.mergeBranch = false
                mergeBranch(selected)
            }
        }
        .confirmationDialog("Checkout Selected Commit", isPresented: Binding(
            get: { checkoutConfirmation != nil }, set: { if !$0 { checkoutConfirmation = nil } }
        ), titleVisibility: .visible) {
            if let commit = checkoutConfirmation {
                Button("Checkout") {
                    runMenuOperation("Checkout") { try await GitRuntime.run(GitCheckout(directory: folder.url, commitHash: commit.hash)) }
                }
            }
        } message: {
            if let commit = checkoutConfirmation { Text(verbatim: String(commit.hash.prefix(12)) + " · " + commit.title) }
        }
        .confirmationDialog("Revert Selected Commit", isPresented: Binding(
            get: { revertConfirmation != nil }, set: { if !$0 { revertConfirmation = nil } }
        ), titleVisibility: .visible) {
            if let commit = revertConfirmation {
                Button("Revert") {
                    runMenuOperation("Revert") {
                        try await GitRuntime.run(GitRevert(directory: folder.url,
                            parentNumber: commit.revertMainline, commit: commit.hash))
                    }
                }
            }
        } message: {
            if let commit = revertConfirmation { Text(verbatim: String(commit.hash.prefix(12)) + " · " + commit.title) }
        }
        .errorSheet($error, operation: "Load Repository")
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
                            if let reason = syncState.syncError {
                                error = OperationFailure("Synchronize Repository", GenericError(errorDescription: reason))
                            }
                        } label: {
                            Label {
                                Text("Sync Error")
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                            }
                        }
                        .help("Sync Error")
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
                OpenInMenu(directory: folder.url, store: menuApplications, onError: { error = $0 })
            }
            ToolbarSpacer(.flexible, placement: .primaryAction)
            ToolbarItem(id: "commandLog", placement: .primaryAction) {
                Button { toggleCommandLog() } label: {
                    Label("Log", systemImage: "terminal")
                }
                .help("Log")
                .accessibilityIdentifier("toggleCommandLog")
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

    private var menuContext: RepositoryMenuContext {
        var actions = MenuActions()
        if !isLoading && !isFetching && !showing.isPresented && checkoutConfirmation == nil && revertConfirmation == nil {
            actions[.refresh] = { Task { await refreshModels() } }
            actions[.fetch] = fetchChanges
            actions[.searchCommits] = { searchFocusRequest = UUID() }
            actions[.showBranches] = { showing.branches = true }
            actions[.newBranch] = { showing.createNewBranchFrom = branch ?? Branch(name: "HEAD", isCurrent: true) }
            actions[.showTags] = { showing.tags = true }
            actions[.showStashes] = { showing.stashChanged = true }
            actions[.compare] = { showing.compareRevisions = true }
            if !menuApplications.isOpening { actions[.chooseApplication] = chooseMenuApplication }
            actions[.showChanges] = {
                searchText = ""
                Task {
                    await logStore.revealWorkingTree()
                    subSelectionLogID = nil
                    selectionLogID = Log.notCommitted.id
                    selectionLog = .notCommitted
                }
            }
            if logStore.snapshot?.headHash != nil {
                actions[.revealHead] = {
                    searchText = ""
                    Task {
                        if let target = await logStore.revealHead() {
                            subSelectionLogID = nil
                            selectionLogID = target
                        }
                    }
                }
            }
            if let branch, !branch.isDetached {
                actions[.renameBranch] = { showing.renameBranch = branch }
                actions[.mergeBranch] = { showing.mergeBranch = true }
                actions[.push] = pushChanges
                if syncState.tracking?.upstream != nil { actions[.pull] = pullChanges }
            }
            if logStore.notCommitted?.isEmpty == false {
                actions[.stash] = { runMenuOperation("Stash All Changes") { try await GitRuntime.run(GitStash(directory: folder.url)) } }
            }
            if let terminal = Self.terminalURL {
                actions[.openTerminal] = {
                    Task {
                        do {
                            _ = try await NSWorkspace.shared.open([folder.url], withApplicationAt: terminal,
                                                                 configuration: NSWorkspace.OpenConfiguration())
                        } catch { self.error = OperationFailure("Open Terminal", error) }
                    }
                }
            }
            if let target = selectedCommit {
                actions[.copyCommitHash] = {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(target.hash, forType: .string)
                }
                actions[.newTag] = { showing.createNewTagAt = target }
                actions[.checkoutCommit] = { checkoutConfirmation = target }
                actions[.revertCommit] = { revertConfirmation = target }
                if target.hash == logStore.snapshot?.headHash && logStore.notCommitted?.diffCached.isEmpty != false {
                    actions[.amendCommit] = { showing.amendCommitAt = target }
                }
            } else if let head = logStore.commits.first(where: { $0.hash == logStore.snapshot?.headHash }) {
                actions[.newTag] = { showing.createNewTagAt = head }
            }
        }
        return RepositoryMenuContext(actions: actions, directory: folder.url, historyScope: logStore.scope,
            setHistoryScope: { scope in Task { await logStore.setScope(scope) } },
            applications: menuApplications.pinned + menuApplications.suggested + menuApplications.others,
            openApplication: { application in openMenuApplication(application) },
            isOpeningApplication: menuApplications.isOpening)
    }

    private func chooseMenuApplication() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Application")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let application = OpenInApplication.read(at: url), application.id != Bundle.main.bundleIdentifier else {
                error = OperationFailure("Choose Application", GenericError(errorDescription:
                    String(localized: "Choose another application to open the project folder.")))
                return
            }
            openMenuApplication(application, remember: true)
        }
    }

    private func openMenuApplication(_ application: OpenInApplication, remember: Bool = false) {
        Task {
            do {
                try await menuApplications.open(application, directory: folder.url, rememberApplication: remember)
            } catch { self.error = OperationFailure("Open in", error) }
        }
    }

    private var selectedCommit: Commit? {
        guard subSelectionLogID == nil, case let .committed(commit) = selectionLog else { return nil }
        return commit
    }

    private func runMenuOperation(_ name: LocalizedStringResource, _ operation: @escaping @MainActor () async throws -> Void) {
        guard !isLoading, !isFetching else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do { try await operation() } catch { self.error = OperationFailure(name, error) }
            await refreshModels()
        }
    }

    private func mergeBranch(_ branch: Branch) {
        guard !isLoading, !isFetching else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                try await GitRuntime.run(GitMerge(directory: folder.url, branchName: branch.name))
            } catch {
                let state = try? await GitMergeState.read(in: folder.url)
                if state?.isMerging != true { self.error = OperationFailure("Merge", error) }
            }
            await refreshModels()
            if session.mergeState?.isMerging == true { showing.mergeResolution = true }
        }
    }

    /// Only opening the repository fetches; local operations refresh from local refs.
    private func refreshModels(fetchRemote: Bool = false) async {
        await session.refresh(in: folder.url, fetchRemote: fetchRemote)
        guard !Task.isCancelled else { return }
        if let error = session.error { self.error = OperationFailure("Load Repository", error) }
        if let selectionLog { self.selectionLog = logStore.logs().first { $0.id == selectionLog.id } }
    }

    fileprivate func branchesButton() -> some View {
        Button {
            showing.branches.toggle()
        } label: {
            Label {
                Text("Branch")
            } icon: {
                HStack(spacing: 8) {
                    Image.gitBranch
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
                            self.error = OperationFailure("Checkout", error)
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
                            self.error = OperationFailure("Checkout", error)
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
                            if mergeState?.isMerging != true { self.error = OperationFailure("Merge", error) }
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
            Label("New Branch", systemImage: "plus")
        }
        .help("New Branch")
    }

    fileprivate func tagButton() -> some View {
        Button {
            showing.tags.toggle()
        } label: {
            Label("Tags", systemImage: "tag")
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
            Label("Stashes", systemImage: "tray")
        }
        .help("Show Stashes")
    }

    fileprivate func compareButton() -> some View {
        Button {
            showing.compareRevisions = true
        } label: {
            Label("Compare", systemImage: "arrow.left.arrow.right")
        }
        .help("Compare Branches or Tags")
    }

    private func fetchButton() -> some View {
        Button(action: fetchChanges) {
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

    private func fetchChanges() {
        guard !isFetching, !isLoading else { return }
        isFetching = true
        Task {
            defer { isFetching = false }
            do {
                try await RemoteUpdateService.shared.execute(GitFetch(directory: folder.url))
                AutoFetchScheduler.shared.recordFetchSuccess(for: folder.url)
                syncState.syncError = nil
                await refreshModels()
            } catch {
                syncState.syncError = error.localizedDescription
                self.error = OperationFailure("Fetch", error)
            }
        }
    }

    fileprivate func pullButton() -> some View {
        PullToolbarButton(count: pullBehindCount, toolTip: pullDescription, onPull: pullChanges)
    }

    private func pullChanges() {
        guard !isLoading, !isFetching else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                guard let branch, !branch.isDetached else {
                    throw GenericError(errorDescription: String(localized: "Switch to a branch before pulling or pushing."))
                }
                guard let tracking = try await TrackingBranch.inspect(in: folder.url, branch: branch.name) else {
                    throw GenericError(errorDescription: String(localized: "No remote repository is configured."))
                }
                guard tracking.upstream != nil else {
                    throw GenericError(errorDescription: String(localized: "No upstream branch is configured. Push this branch to set its upstream before pulling."))
                }
                try await RemoteUpdateService.shared.execute(GitPull(directory: folder.url, refspec: tracking.remoteBranch, remote: tracking.remote))
                syncState.shouldPull = false
                isLoading = false
                await refreshModels()
            } catch {
                isLoading = false
                self.error = OperationFailure("Pull", error)
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
        guard !isLoading, !isFetching else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                guard let branch, !branch.isDetached else {
                    throw GenericError(errorDescription: String(localized: "Switch to a branch before pulling or pushing."))
                }
                guard let tracking = try await TrackingBranch.inspect(in: folder.url, branch: branch.name) else {
                    throw GenericError(errorDescription: String(localized: "No remote repository is configured."))
                }
                try await GitRuntime.run(GitPush(directory: folder.url, refspec: "HEAD:refs/heads/\(tracking.remoteBranch)", remote: tracking.remote, setUpstream: tracking.upstream == nil))
                syncState.shouldPush = false
                isLoading = false
                await refreshModels()
            } catch {
                isLoading = false
                self.error = OperationFailure("Push", error)
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
