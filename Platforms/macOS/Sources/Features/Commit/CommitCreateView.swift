import FoldGitCore
import os
import SwiftUI

struct CommitCreateView: View {
    @AppStorage(PreferenceKey.diffFileExpansion.rawValue) private var fileExpansion = AppPreferences.defaultDiffFileExpansion
    @AppStorage(PreferenceKey.changeFileLayout.rawValue) private var changeFileLayout = AppPreferences.defaultChangeFileLayout
    @AppStorage(PreferenceKey.disableCommitOperations.rawValue)
    private var disableCommitOperations = PreferenceDefaults.disableCommitOperations
    @Environment(\.expandAllFiles) private var expandAllFilesID: UUID?
    @Environment(\.collapseAllFiles) private var collapseAllFilesID: UUID?
    @Environment(\.openSettings) var openSettings: OpenSettingsAction
    @Environment(\.appearsActive) private var appearsActive
    @AppStorage(PreferenceKey.untrackedFilesExpanded.rawValue) private var isUntrackedExpanded = true

    var folder: WorkspaceEntry
    @State private var cachedDiffShortStat = ""
    @State private var diffShortStat = ""
    private var notStagedHeaderCaption: String {
        if let untrackedStat = status?.untrackedFilesShortStat, !untrackedStat.isEmpty {
            if diffShortStat.isEmpty {
                return untrackedStat
            } else {
                return String(localized: "\(diffShortStat), \(untrackedStat)", comment: "Joins tracked and untracked change summaries. Translators may change the separator.")
            }
        }
        return diffShortStat
    }
    private var canStage: Bool {
        if !diffRaw.isEmpty {
            return true
        }
        if let untrackedFiles = status?.untrackedFiles {
            if !untrackedFiles.isEmpty {
                return true
            }
        }

        return false
    }
    @State private var cachedDiffRaw = ""
    @State private var diffRaw = ""
    @State private var cachedDiff: Diff?
    @State private var cachedExpandableFileDiffs: [ExpandableModel<FileDiff>] = []
    @State private var diff: Diff?
    @State private var expandableFileDiffs: [ExpandableModel<FileDiff>] = []
    @State private var status: Status?
    @State private var cachedDiffStat: DiffStat?
    @State private var updateChangesError: Error?
    @State private var updateGeneration = 0
    @State private var diffFileRefreshID = 0
    private var drafts = CommitDraftStore.shared
    private var commitMessage: Binding<String> { drafts.binding(for: folder.url) }
    @State private var error: Error?
    @State private var isStagingChanges = false
    @State private var stagedPaneHeight: CGFloat = 180
    @State private var stagedTree = ChangeFileTree()
    @State private var unstagedTree = ChangeFileTree()
    @State private var untrackedTree = ChangeFileTree()
    @State private var collapsedStagedDirectories: Set<String> = []
    @State private var collapsedUnstagedDirectories: Set<String> = []
    @State private var collapsedUntrackedDirectories: Set<String> = []
    @State private var isStagedExpanded = true
    @State private var isUnstagedExpanded = true
    @State private var selectedUnstaged: Set<String> = []
    @State private var selectedStaged: Set<String> = []
    @State private var selectionAnchor: String?
    @FocusState private var focusedPane: ChangePane?
    @State private var pendingDiscard: PendingDiscard?
    @State private var isStashSheetPresented = false
    @State private var stashMessage = ""
    @State private var expandedUntrackedImages: Set<String> = []
    @State private var stagedLanding: Set<String> = []
    @State private var unstagedLanding: Set<String> = []
    @State private var landingGeneration = 0
    @State private var stagedScrollTarget: AnyHashable?
    @State private var unstagedScrollTarget: AnyHashable?
    @Binding var isRefresh: Bool
    var onCommit: () -> Void
    var onStash: () -> Void

    init(folder: WorkspaceEntry, isRefresh: Binding<Bool>, onCommit: @escaping () -> Void, onStash: @escaping () -> Void) {
        self.folder = folder
        _isRefresh = isRefresh
        self.onCommit = onCommit
        self.onStash = onStash
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // VSplitView kept the staged list at its first layout size after resizing the pane,
            // which left blank space above the heading. This split sizes the pane explicitly.
            if disableCommitOperations {
                ScrollView {
                    unstagedChanges
                    loadError
                    if !cachedExpandableFileDiffs.isEmpty {
                        Text("Staged Changes").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding()
                        StageFileDiffsView(expandableFileDiffs: $cachedExpandableFileDiffs,
                            selectButtonImageSystemName: "minus", selectFileButtonHelp: String(localized: "Unstage This File"),
                            selectButtonHelp: String(localized: "Unstage This Hunk"), onSelectFileDiff: nil, onSelectChunk: nil,
                            layout: changeFileLayout, tree: stagedTree, collapsedDirectories: $collapsedStagedDirectories)
                            .environment(\.diffFileContext, .staged)
                            .environment(\.changeRowContext, rowContext(staged: true))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    let stagedHeight = cachedExpandableFileDiffs.isEmpty
                        ? 44 : min(max(72, stagedPaneHeight), max(72, geometry.size.height - 73))
                    VStack(spacing: 0) {
                        ScrollViewReader { proxy in
                            ScrollView {
                                unstagedChanges
                                loadError
                            }
                            .scrollEdgeEffectStyle(.hard, for: .vertical)
                            .frame(maxHeight: .infinity)
                            .changePaneKeyboard(staged: false, focus: $focusedPane, onActivate: { stageSelection(staged: false) })
                            .dropDestination(for: String.self) { items, _ in _ = dropFiles(items, staged: false) }
                            .accessibilityIdentifier("unstagedChangesPane")
                            .scrollsToStageLanding(unstagedScrollTarget, with: proxy)
                        }

                        PaneResizeHandle(height: $stagedPaneHeight, current: stagedHeight, defaultHeight: 180,
                                         isEnabled: !cachedExpandableFileDiffs.isEmpty)
                        stagedChanges
                            .frame(height: stagedHeight, alignment: .top)
                            .clipped()
                            .changePaneKeyboard(staged: true, focus: $focusedPane, onActivate: { stageSelection(staged: true) })
                            .dropDestination(for: String.self) { items, _ in _ = dropFiles(items, staged: true) }
                            .accessibilityIdentifier("stagedChangesPane")
                    }
                }

            }

            VStack(spacing: 0) {
                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack {
                        changeControls
                        Spacer(minLength: 12)
                        changeActions
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 10) {
                        changeControls
                        changeActions
                    }
                }
                .textSelection(.disabled)
                .font(.callout)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.horizontal)

                if !disableCommitOperations {
                    CommitMessageEditor(
                        folder: folder,
                        commitMessage: commitMessage,
                        cachedDiffStat: $cachedDiffStat,
                        error: $error,
                        cachedDiffRaw: $cachedDiffRaw) {
                            onCommit()
                        }
                        .frame(height: CommitMessageEditor.height)
                        .disabled(isStagingChanges)
                }
            }
            .background(.bar)
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.textBackgroundColor))
        .onChange(of: isRefresh, { oldValue, newValue in
            if newValue {
                Task {
                    await updateChanges()
                }
            }
        })
        .onChange(of: appearsActive, { oldValue, newValue in
            if newValue {
                Task {
                    await updateChanges()
                }
            }
        })
        .task {
            await updateChanges()
        }
        .errorSheet($error, operation: "Load Changes")
        .confirmationDialog(pendingDiscard?.title ?? "", isPresented: Binding(get: { pendingDiscard != nil },
                                                                             set: { if !$0 { pendingDiscard = nil } }),
                            titleVisibility: .visible, presenting: pendingDiscard) { discard in
            Button(discard.untracked.isEmpty ? LocalizedStringKey("Discard Changes") : "Discard and Move to Trash", role: .destructive) {
                performDiscard(discard)
            }
            .accessibilityIdentifier("confirmDiscardChangesButton")
            Button("Cancel", role: .cancel) { pendingDiscard = nil }
        } message: { discard in
            Text(verbatim: discard.message)
        }
        .sheet(isPresented: $isStashSheetPresented) {
            StashChangesSheet(message: $stashMessage, onStash: confirmStash)
        }
        .environment(\.diffFileRefreshID, diffFileRefreshID)
        .focusedSceneValue(\.stagingMenu, menuActions)
        .onChange(of: expandAllFilesID) { _, _ in setAllDiffExpansion(true) }
        .onChange(of: collapseAllFilesID) { _, _ in setAllDiffExpansion(false) }
    }

    @ViewBuilder
    private var unstagedChanges: some View {
        if diff != nil {
            UnstagedView(
                fileDiffs: $expandableFileDiffs,
                status: notStagedHeaderCaption,
                untrackedFiles: status?.untrackedFiles ?? [],
                onSelectFileDiff: isStagingChanges || disableCommitOperations ? nil : { fileDiff in
                    if let newDiff = self.diff?.updateFileDiffStage(fileDiff, stage: true) {
                        addPatch(newDiff, landing: fileDiff.changeTreePath)
                    }
                },
                onSelectChunk: isStagingChanges || disableCommitOperations || status?.unmergedFiles.isEmpty == false ? nil : { fileDiff, chunk in
                    if let newDiff = self.diff?.updateChunkStage(chunk, in: fileDiff, stage: true) {
                        addPatch(newDiff, landing: fileDiff.changeTreePath)
                    }
                },
                onSelectUntrackedFile: isStagingChanges || disableCommitOperations ? nil : { file in
                    updateIndex("Stage Changes", staging: true, landing: [file]) {
                        try await GitRuntime.run(GitAddPathspec(directory: folder.url, pathspec: file))
                    }
                },
                layout: changeFileLayout,
                tree: unstagedTree,
                untrackedTree: untrackedTree,
                collapsedDirectories: $collapsedUnstagedDirectories,
                collapsedUntrackedDirectories: $collapsedUntrackedDirectories,
                isExpanded: $isUnstagedExpanded,
                isUntrackedExpanded: $isUntrackedExpanded,
                expandedUntrackedImages: $expandedUntrackedImages,
                onSelectDirectory: isStagingChanges || disableCommitOperations ? nil : { stageDirectory($0, staging: true) }
            )
            .padding(.top)
            .environment(\.stageLandingPaths, unstagedLanding)
            .environment(\.changeRowContext, rowContext(staged: false))
        } else if updateChangesError == nil {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.top, 48)
        }
    }

    @ViewBuilder
    private var stagedChanges: some View {
        if cachedDiff != nil {
            StagedView(
                fileDiffs: $cachedExpandableFileDiffs,
                status: cachedDiffShortStat,
                onSelectFileDiff: isStagingChanges || disableCommitOperations ? nil : { fileDiff in
                    if let newDiff = self.cachedDiff?.updateFileDiffStage(fileDiff, stage: false) {
                        restorePatch(newDiff, landing: fileDiff.changeTreePath)
                    }
                },
                onSelectChunk: isStagingChanges || disableCommitOperations || status?.unmergedFiles.isEmpty == false ? nil : { fileDiff, chunk in
                    if let newDiff = self.cachedDiff?.updateChunkStage(chunk, in: fileDiff, stage: false) {
                        restorePatch(newDiff, landing: fileDiff.changeTreePath)
                    }
                },
                layout: changeFileLayout,
                tree: stagedTree,
                collapsedDirectories: $collapsedStagedDirectories,
                isExpanded: $isStagedExpanded,
                onSelectDirectory: isStagingChanges || disableCommitOperations ? nil : { stageDirectory($0, staging: false) },
                scrollTarget: stagedScrollTarget
            )
            .environment(\.stageLandingPaths, stagedLanding)
            .environment(\.changeRowContext, rowContext(staged: true))
        }
    }

    /// Replaces the raw Git output with a readable failure and a way to retry.
    @ViewBuilder
    private var loadError: some View {
        if let updateChangesError {
            ContentUnavailableView {
                Label("Unable to Load Changes", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: updateChangesError.localizedDescription)
                    .textSelection(.enabled)
            } actions: {
                Button("Try Again") { Task { await updateChanges() } }
                    .accessibilityIdentifier("retryLoadChangesButton")
            }
            .padding(.top, diff == nil ? 32 : 8)
        }
    }

    private var changeControls: some View {
        DiffDisplayControls(changeFileLayout: $changeFileLayout,
                            onExpandDirectories: { setAllDirectoryExpansion(true) },
                            onCollapseDirectories: { setAllDirectoryExpansion(false) },
                            onExpandAll: { setAllDiffExpansion(true) },
                            onCollapseAll: { setAllDiffExpansion(false) })
    }

    private func setAllDiffExpansion(_ expanded: Bool) {
        cachedExpandableFileDiffs = cachedExpandableFileDiffs.settingExpansion(expanded)
        expandableFileDiffs = expandableFileDiffs.settingExpansion(expanded)
        expandedUntrackedImages = expanded ? Set((status?.untrackedFiles ?? []).filter { DiffImage.supports(path: $0) }) : []
    }

    private func setAllDirectoryExpansion(_ expanded: Bool) {
        collapsedStagedDirectories = expanded ? [] : stagedTree.directoryPaths
        collapsedUnstagedDirectories = expanded ? [] : unstagedTree.directoryPaths
        collapsedUntrackedDirectories = expanded ? [] : untrackedTree.directoryPaths
    }

    private var changeActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { stagingActions }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 8) { stagingActions }
        }
    }

    @ViewBuilder
    private var stagingActions: some View {
        Button("Stash All Changes", action: stashChanges)
        .disabled(isStagingChanges || (!canStage && cachedDiffRaw.isEmpty))
        .fixedSize()

        if !disableCommitOperations {
            Button("Stage All", action: stageAll)
            .disabled(!canStage || isStagingChanges)
            .fixedSize()

            Button("Unstage All", action: unstageAll)
            .disabled(cachedDiffRaw.isEmpty || isStagingChanges)
            .fixedSize()
        }
    }

    private var menuActions: MenuActions {
        var actions = MenuActions()
        if changeFileLayout == .tree {
            actions[.expandDirectories] = { setAllDirectoryExpansion(true) }
            actions[.collapseDirectories] = { setAllDirectoryExpansion(false) }
        }
        guard !isStagingChanges else { return actions }
        if !disableCommitOperations && canStage { actions[.stageAll] = stageAll }
        if !disableCommitOperations && !cachedDiffRaw.isEmpty { actions[.unstageAll] = unstageAll }
        if canStage || !cachedDiffRaw.isEmpty { actions[.stash] = stashChanges }
        return actions
    }

    private func stageAll() {
        guard !disableCommitOperations else { return }
        updateIndex("Stage Changes", staging: true) { try await GitRuntime.run(GitAdd(directory: folder.url)) }
    }

    private func unstageAll() {
        guard !disableCommitOperations else { return }
        updateIndex("Unstage Changes", staging: false) { try await GitRuntime.run(GitRestore(directory: folder.url)) }
    }

    private func stageDirectory(_ path: String, staging: Bool) {
        guard let diff = staging ? diff : cachedDiff else { return }
        let selection = ChangeDirectoryStaging.selection(in: path, diff: diff,
                                                        untrackedFiles: status?.untrackedFiles ?? [], staging: staging)
        guard !selection.isEmpty else { return }
        updateIndex(staging ? "Stage Changes" : "Unstage Changes", staging: staging) { try await IndexStaging.apply(selection, staging: staging, in: folder.url) }
    }

    /// Asks for an optional message first, so stashing never happens from a single stray click.
    private func stashChanges() {
        guard !isStagingChanges else { return }
        stashMessage = ""
        isStashSheetPresented = true
    }

    private func confirmStash() {
        let message = stashMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        isStashSheetPresented = false
        updateIndex("Stash All Changes") {
            try await GitRuntime.run(GitStash(directory: folder.url, message: message))
            onStash()
        }
    }

    // MARK: Selection

    private func orderedPaths(staged: Bool) -> [String] {
        let tracked: [String]
        if changeFileLayout == .tree {
            tracked = (staged ? stagedTree : unstagedTree).rows.filter { !$0.isDirectory }.map(\.path)
        } else {
            tracked = (staged ? cachedExpandableFileDiffs : expandableFileDiffs).map(\.model.changeTreePath)
        }
        guard !staged else { return tracked }
        let untracked = changeFileLayout == .tree
            ? untrackedTree.rows.filter { !$0.isDirectory }.map(\.path)
            : status?.untrackedFiles ?? []
        return tracked + untracked
    }

    /// Command toggles a row, Shift extends from the last clicked row, and a plain click selects one row.
    private func select(_ path: String, staged: Bool) {
        let flags = NSEvent.modifierFlags
        var selection = staged ? selectedStaged : selectedUnstaged
        if flags.contains(.command) {
            if selection.contains(path) { selection.remove(path) } else { selection.insert(path) }
            selectionAnchor = path
        } else if flags.contains(.shift), let anchor = selectionAnchor, selection.contains(anchor) {
            let order = orderedPaths(staged: staged)
            if let start = order.firstIndex(of: anchor), let end = order.firstIndex(of: path) {
                selection = Set(order[min(start, end)...max(start, end)])
            } else {
                selection = [path]
            }
        } else {
            selection = [path]
            selectionAnchor = path
        }
        if staged {
            selectedStaged = selection
            selectedUnstaged = []
        } else {
            selectedUnstaged = selection
            selectedStaged = []
        }
        focusedPane = staged ? .staged : .unstaged
    }

    private var canChangeIndex: Bool { !isStagingChanges && !disableCommitOperations }

    private func rowContext(staged: Bool) -> ChangeRowContext {
        let hasConflicts = status?.unmergedFiles.isEmpty == false
        return ChangeRowContext(
            directory: folder.url,
            isStaged: staged,
            selection: staged ? selectedStaged : selectedUnstaged,
            select: { select($0, staged: staged) },
            stage: canChangeIndex ? { stagePaths($0, staging: !staged) } : nil,
            discard: canChangeIndex && !staged ? { requestDiscard($0) } : nil,
            discardChunk: canChangeIndex && !staged && !hasConflicts ? { requestDiscard($0, chunk: $1) } : nil
        )
    }

    private func stageSelection(staged: Bool) {
        let selection = staged ? selectedStaged : selectedUnstaged
        guard canChangeIndex, !selection.isEmpty else { return }
        stagePaths(selection.sorted(), staging: !staged)
    }

    private func dropFiles(_ items: [String], staged: Bool) -> Bool {
        guard canChangeIndex else { return false }
        let paths = items.compactMap { ChangeDragPayload.decode($0, droppingInto: staged, directory: folder.url) }.flatMap { $0 }
        guard !paths.isEmpty else { return false }
        stagePaths(paths, staging: staged)
        return true
    }

    /// Stages or unstages whole files, including untracked files and both sides of a rename.
    private func stagePaths(_ paths: [String], staging: Bool) {
        guard canChangeIndex, let source = staging ? diff : cachedDiff else { return }
        let wanted = Set(paths)
        var selected = source
        selected.fileDiffs = source.fileDiffs.filter { wanted.contains($0.changeTreePath) }
        var selection = selected.updateAll(stage: staging).indexSelection(staging: staging)
        let renameSources = selected.fileDiffs.filter { $0.change.kind == .renamed }.map(\.fromFilePath)
        let untracked = staging ? (status?.untrackedFiles ?? []).filter(wanted.contains) : []
        selection.paths = Array(Set(selection.paths + renameSources + untracked)).sorted()
        guard !selection.isEmpty else { return }
        updateIndex(staging ? "Stage Changes" : "Unstage Changes", staging: staging, landing: wanted) {
            try await IndexStaging.apply(selection, staging: staging, in: folder.url)
        }
    }

    // MARK: Discarding

    private func requestDiscard(_ paths: [String]) {
        guard canChangeIndex else { return }
        let wanted = Set(paths)
        let tracked = (diff?.fileDiffs ?? []).map(\.changeTreePath).filter(wanted.contains)
        let untracked = (status?.untrackedFiles ?? []).filter(wanted.contains)
        guard !tracked.isEmpty || !untracked.isEmpty else { return }
        pendingDiscard = PendingDiscard(tracked: tracked, untracked: untracked)
    }

    private func requestDiscard(_ fileDiff: FileDiff, chunk: Chunk) {
        guard canChangeIndex else { return }
        pendingDiscard = PendingDiscard(tracked: [fileDiff.changeTreePath], untracked: [], chunk: (fileDiff, chunk))
    }

    private func performDiscard(_ discard: PendingDiscard) {
        pendingDiscard = nil
        guard canChangeIndex, let diff else { return }
        let selection: IndexSelection
        if let target = discard.chunk {
            selection = diff.updateChunkStage(target.1, in: target.0, stage: true).indexSelection(staging: true)
        } else {
            let wanted = Set(discard.tracked)
            var selected = diff
            selected.fileDiffs = diff.fileDiffs.filter { wanted.contains($0.changeTreePath) }
            selection = selected.updateAll(stage: true).indexSelection(staging: true)
        }
        let directory = folder.url
        updateIndex("Discard Changes") {
            try CommitOperations.requireEnabled()
            if !selection.isEmpty { try await WorktreeDiscarding.discard(selection, in: directory) }
            if !discard.untracked.isEmpty { try WorktreeDiscarding.trashUntrackedFiles(discard.untracked, in: directory) }
        }
        selectedUnstaged.subtract(discard.untracked)
        if discard.chunk == nil { selectedUnstaged.subtract(discard.tracked) }
    }

    /// `staging` names the pane files move into, so the rows that land there can be highlighted once the lists refresh.
    private func updateIndex(_ name: LocalizedStringResource, refreshing: Bool = true, staging: Bool? = nil,
                             landing: Set<String> = [], _ operation: @escaping @MainActor () async throws -> Void) {
        guard !isStagingChanges else { return }
        isStagingChanges = true
        let before = staging.map { paneFiles(staged: $0) }
        Task {
            defer { isStagingChanges = false }
            do {
                try await operation()
                if refreshing { await updateChanges() }
            } catch {
                self.error = OperationFailure(name, error)
                return
            }
            if let staging, let before {
                highlightLanding(paneFiles(staged: staging).subtracting(before).union(landing), staged: staging)
            }
        }
    }

    private func paneFiles(staged: Bool) -> Set<String> {
        if staged { return Set(cachedExpandableFileDiffs.map(\.model.changeTreePath)) }
        return Set(expandableFileDiffs.map(\.model.changeTreePath)).union(status?.untrackedFiles ?? [])
    }

    private func highlightLanding(_ paths: Set<String>, staged: Bool) {
        guard !paths.isEmpty else { return }
        landingGeneration += 1
        let generation = landingGeneration
        let target = paths.sorted().lazy.compactMap { scrollTarget(for: $0, staged: staged) }.first
        if staged {
            stagedLanding = paths
            stagedScrollTarget = target
        } else {
            unstagedLanding = paths
            unstagedScrollTarget = target
        }
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            // A later update owns the highlight now; leave its rows lit.
            guard generation == landingGeneration else { return }
            stagedLanding = []
            unstagedLanding = []
            stagedScrollTarget = nil
            unstagedScrollTarget = nil
        }
    }

    /// The row that shows `path`: its own, or the collapsed folder or section that hides it.
    private func scrollTarget(for path: String, staged: Bool) -> AnyHashable? {
        if !staged, status?.untrackedFiles.contains(path) == true {
            guard isUntrackedExpanded else { return AnyHashable(StageLandingAnchor.untrackedFiles) }
            return changeFileLayout == .tree
                ? treeRowID(path, fileID: path, collapsed: collapsedUntrackedDirectories)
                : AnyHashable(path)
        }
        let files = staged ? cachedExpandableFileDiffs : expandableFileDiffs
        guard let id = files.first(where: { $0.model.changeTreePath == path })?.model.id else { return nil }
        return changeFileLayout == .tree
            ? treeRowID(path, fileID: id, collapsed: staged ? collapsedStagedDirectories : collapsedUnstagedDirectories)
            : AnyHashable(id)
    }

    private func treeRowID(_ path: String, fileID: String, collapsed: Set<String>) -> AnyHashable {
        var directory = ""
        for part in path.split(separator: "/").dropLast() {
            directory += directory.isEmpty ? String(part) : "/" + part
            if collapsed.contains(directory) { return AnyHashable(ChangeFileTree.Row.ID.directory(directory)) }
        }
        return AnyHashable(ChangeFileTree.Row.ID.file(fileID))
    }

    private func updateChanges() async {
        updateGeneration += 1
        let request = updateGeneration
        // The read below queues behind other Git work, such as the fetch that runs when a repository opens.
        async let fresh = WorktreeSnapshot.read(in: folder.url)
        if diff == nil, let cached = WorktreeSnapshotCache.snapshot(in: folder.url) {
            _ = try? await show(cached, request: request)
        }
        do {
            let snapshot = try await fresh
            try Task.checkCancellation()
            guard request == updateGeneration else { return }
            WorktreeSnapshotCache.store(snapshot, in: folder.url)
            guard try await show(snapshot, request: request) else { return }
            updateChangesError = nil
            diffFileRefreshID = request
            Task {
                if commitMessage.wrappedValue.isEmpty,
                   let message = try? await DefaultMergeCommitMessage(directory: folder.url).get() {
                    commitMessage.wrappedValue = message
                }
            }
        } catch {
            guard request == updateGeneration, !Task.isCancelled else { return }
            updateChangesError = OperationFailure("Load Changes", error)
        }
    }

    /// Parses off the main actor, and only when Git's output changed, so large diffs never stall the window.
    private func show(_ snapshot: WorktreeSnapshot, request: Int) async throws -> Bool {
        if diff == nil || cachedDiff == nil || snapshot.unstaged != diffRaw || snapshot.staged != cachedDiffRaw {
            let changes = try await Task.detached(priority: .userInitiated) { try ParsedChanges(snapshot) }.value
            guard request == updateGeneration else { return false }
            diffShortStat = GitSummary.describe(changes.unstagedStatistics)
            cachedDiffShortStat = GitSummary.describe(changes.stagedStatistics)
            cachedDiffRaw = snapshot.staged
            diffRaw = snapshot.unstaged
            cachedDiff = changes.staged
            cachedExpandableFileDiffs = changes.staged.fileDiffs.withExpansionState(from: cachedExpandableFileDiffs, defaultIsExpanded: fileExpansion.isExpanded)
            diff = changes.unstaged
            expandableFileDiffs = changes.unstaged.fileDiffs.withExpansionState(from: expandableFileDiffs, defaultIsExpanded: fileExpansion.isExpanded)
            cachedDiffStat = changes.stagedStatistics
            stagedTree = changes.stagedTree
            unstagedTree = changes.unstagedTree
            collapsedStagedDirectories.formIntersection(stagedTree.directoryPaths)
            collapsedUnstagedDirectories.formIntersection(unstagedTree.directoryPaths)
        }
        if status?.untrackedFiles != snapshot.status.untrackedFiles {
            let files = snapshot.status.untrackedFiles
            let tree = await Task.detached(priority: .userInitiated) { ChangeFileTree(untrackedFiles: files) }.value
            guard request == updateGeneration else { return false }
            untrackedTree = tree
            collapsedUntrackedDirectories.formIntersection(tree.directoryPaths)
            expandedUntrackedImages.formIntersection(files)
        }
        guard request == updateGeneration else { return false }
        status = snapshot.status
        // Keep the selection for files that are still in the same pane.
        let unstagedPaths = paneFiles(staged: false)
        let stagedPaths = paneFiles(staged: true)
        if !selectedUnstaged.isSubset(of: unstagedPaths) { selectedUnstaged.formIntersection(unstagedPaths) }
        if !selectedStaged.isSubset(of: stagedPaths) { selectedStaged.formIntersection(stagedPaths) }
        return true
    }

    private func restorePatch(_ newDiff: Diff, landing: String) {
        updateIndex("Unstage Changes", staging: false, landing: [landing]) { try await IndexStaging.apply(newDiff.indexSelection(staging: false), staging: false, in: folder.url) }
    }

    private func addPatch(_ newDiff: Diff, landing: String) {
        updateIndex("Stage Changes", staging: true, landing: [landing]) { try await IndexStaging.apply(newDiff.indexSelection(staging: true), staging: true, in: folder.url) }
    }
}

enum ChangePane: Hashable { case unstaged, staged }

/// Unstaged changes the user asked to discard, waiting for confirmation.
struct PendingDiscard {
    let tracked: [String]
    let untracked: [String]
    var chunk: (FileDiff, Chunk)?

    var count: Int { tracked.count + untracked.count }

    var title: String {
        if chunk != nil { return String(localized: "Discard This Hunk?") }
        return String(localized: "Discard Changes to \(count) Files?")
    }

    var message: String {
        var lines = [String(localized: "Unstaged changes will be lost. This can't be undone.")]
        if !untracked.isEmpty {
            lines.append(String(localized: "\(untracked.count) untracked files will be moved to the Trash."))
        }
        return lines.joined(separator: "\n\n")
    }
}

extension View {
    /// Space or Return stages or unstages the selected files of a focused change pane.
    func changePaneKeyboard(staged: Bool, focus: FocusState<ChangePane?>.Binding,
                            onActivate: @escaping () -> Void) -> some View {
        focusable()
            .focusEffectDisabled()
            .focused(focus, equals: staged ? .staged : .unstaged)
            .onKeyPress(keys: [.space, .return]) { _ in
                onActivate()
                return .handled
            }
    }
}

/// Asks for an optional stash message before stashing every change.
private struct StashChangesSheet: View {
    @Binding var message: String
    var onStash: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Stash All Changes").font(.headline)
            Text("Staged, unstaged, and untracked changes are saved in a stash and removed from the working tree.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Stash Message (Optional)", text: $message)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(onStash)
                .accessibilityIdentifier("stashMessageField")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Stash", action: onStash)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("confirmStashButton")
            }
        }
        .padding(24)
        .frame(width: 420)
        .task { isFocused = true }
    }
}

private struct ParsedChanges: Sendable {
    let staged: Diff
    let unstaged: Diff
    let stagedStatistics: DiffStat
    let unstagedStatistics: DiffStat
    let stagedTree: ChangeFileTree
    let unstagedTree: ChangeFileTree

    init(_ snapshot: WorktreeSnapshot) throws {
        staged = try Diff(raw: snapshot.staged)
        unstaged = try Diff(raw: snapshot.unstaged)
        stagedStatistics = DiffStat(diff: staged)
        unstagedStatistics = DiffStat(diff: unstaged)
        stagedTree = ChangeFileTree(fileDiffs: staged.fileDiffs)
        unstagedTree = ChangeFileTree(fileDiffs: unstaged.fileDiffs)
    }
}

/// A horizontal divider that resizes the pane below it. Double-click restores the default height.
private struct PaneResizeHandle: View {
    @Binding var height: CGFloat
    var current: CGFloat
    var defaultHeight: CGFloat
    var isEnabled: Bool
    @State private var startHeight: CGFloat?

    var body: some View {
        Divider()
            .overlay {
                if isEnabled {
                    Color.clear
                        .frame(height: 9)
                        .contentShape(Rectangle())
                        .pointerStyle(.rowResize)
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = startHeight ?? current
                                startHeight = start
                                height = start - value.translation.height
                            }
                            .onEnded { _ in
                                height = current
                                startHeight = nil
                            })
                        .onTapGesture(count: 2) { height = defaultHeight }
                }
            }
            .zIndex(1)
    }
}
