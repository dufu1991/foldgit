import FoldGitCore
import os
import SwiftUI

struct CommitCreateView: View {
    @AppStorage(PreferenceKey.diffFileExpansion.rawValue) private var fileExpansion = DiffFileExpansion.expanded
    @Environment(\.openSettings) var openSettings: OpenSettingsAction
    @Environment(\.appearsActive) private var appearsActive

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
    @State private var imageDiffRefreshID = 0
    @State private var commitMessage = ""
    @State private var error: Error?
    @State private var isAmend = false
    @State private var amendCommit: Commit?
    @State private var isStagingChanges = false
    @State private var stagedPaneHeight: CGFloat = 180
    @Binding var isRefresh: Bool
    var onCommit: () -> Void
    var onStash: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // VSplitView kept the staged list at its first layout size after resizing the pane,
            // which left blank space above the heading. This split sizes the pane explicitly.
            GeometryReader { geometry in
                let stagedHeight = cachedExpandableFileDiffs.isEmpty
                    ? 44 : min(max(72, stagedPaneHeight), max(72, geometry.size.height - 73))
                VStack(spacing: 0) {
                    ScrollView {
                        unstagedChanges

                        if let updateChangesError {
                            Label(updateChangesError.localizedDescription, systemImage: "exclamationmark.octagon")
                            Text(cachedDiffRaw + diffRaw)
                                .padding()
                                .font(Font.system(.body, design: .monospaced))
                        }
                    }
                    .scrollEdgeEffectStyle(.hard, for: .vertical)
                    .frame(maxHeight: .infinity)
                    .accessibilityIdentifier("unstagedChangesPane")

                    PaneResizeHandle(height: $stagedPaneHeight, current: stagedHeight, defaultHeight: 180,
                                     isEnabled: !cachedExpandableFileDiffs.isEmpty)
                    stagedChanges
                        .frame(height: stagedHeight, alignment: .top)
                        .clipped()
                        .accessibilityIdentifier("stagedChangesPane")
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

                CommitMessageEditor(
                    folder: folder,
                    commitMessage: $commitMessage,
                    cachedDiffStat: $cachedDiffStat,
                    isAmend: $isAmend,
                    error: $error,
                    cachedDiffRaw: $cachedDiffRaw,
                    amendCommit: $amendCommit) {
                        onCommit()
                    }
                    .frame(height: 112)
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

            do {
                amendCommit = try await GitRuntime.run(GitLog(directory: folder.url, number: 1)).first
            } catch {
                self.error = error
            }
        }
        .errorSheet($error)
        .environment(\.imageDiffRefreshID, imageDiffRefreshID)
    }

    @ViewBuilder
    private var unstagedChanges: some View {
        if diff != nil {
            UnstagedView(
                fileDiffs: $expandableFileDiffs,
                status: notStagedHeaderCaption,
                untrackedFiles: status?.untrackedFiles ?? [],
                onSelectFileDiff: { fileDiff in
                    if let newDiff = self.diff?.updateFileDiffStage(fileDiff, stage: true) {
                        addPatch(newDiff)
                    }
                },
                onSelectChunk: status?.unmergedFiles.isEmpty == false ? nil : { fileDiff, chunk in
                    if let newDiff = self.diff?.updateChunkStage(chunk, in: fileDiff, stage: true) {
                        addPatch(newDiff)
                    }
                },
                onSelectUntrackedFile: { file in
                    Task {
                        do {
                            try await GitRuntime.run(GitAddPathspec(directory: folder.url, pathspec: file))
                            await updateChanges()
                        } catch {
                            self.error = error
                        }
                    }
                }
            )
            .padding(.top)
        }
    }

    @ViewBuilder
    private var stagedChanges: some View {
        if cachedDiff != nil {
            StagedView(
                fileDiffs: $cachedExpandableFileDiffs,
                status: cachedDiffShortStat,
                onSelectFileDiff: { fileDiff in
                    if let newDiff = self.cachedDiff?.updateFileDiffStage(fileDiff, stage: false) {
                        restorePatch(newDiff)
                    }
                },
                onSelectChunk: status?.unmergedFiles.isEmpty == false ? nil : { fileDiff, chunk in
                    if let newDiff = self.cachedDiff?.updateChunkStage(chunk, in: fileDiff, stage: false) {
                        restorePatch(newDiff)
                    }
                }
            )
        }
    }

    private var changeControls: some View {
        DiffDisplayControls(onExpandAll: {
            cachedExpandableFileDiffs = cachedExpandableFileDiffs.map { ExpandableModel(isExpanded: true, model: $0.model) }
            expandableFileDiffs = expandableFileDiffs.map { ExpandableModel(isExpanded: true, model: $0.model) }
        }, onCollapseAll: {
            cachedExpandableFileDiffs = cachedExpandableFileDiffs.map { ExpandableModel(isExpanded: false, model: $0.model) }
            expandableFileDiffs = expandableFileDiffs.map { ExpandableModel(isExpanded: false, model: $0.model) }
        })
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
        Button("Stash All Changes") {
            Task {
                do {
                    try await GitRuntime.run(GitStash(directory: folder.url))
                    onStash()
                } catch {
                    self.error = error
                }
            }
        }
        .fixedSize()

        Button("Stage All") {
            Task {
                do {
                    try await GitRuntime.run(GitAdd(directory: folder.url))
                    await updateChanges()
                } catch {
                    self.error = error
                }
            }
        }
        .disabled(!canStage)
        .fixedSize()

        Button("Unstage All") {
            Task {
                do {
                    try await GitRuntime.run(GitRestore(directory: folder.url))
                    await updateChanges()
                } catch {
                    self.error = error
                }
            }
        }
        .disabled(cachedDiffRaw.isEmpty)
        .fixedSize()
    }

    private func updateChanges() async {
        updateGeneration += 1
        let request = updateGeneration
        do {
            let snapshot = try await WorktreeSnapshot.read(in: folder.url)
            try Task.checkCancellation()
            guard request == updateGeneration else { return }
            let newCachedDiff = try Diff(raw: snapshot.staged)
            let newDiff = try Diff(raw: snapshot.unstaged)
            let stagedStatistics = DiffStat(diff: newCachedDiff)
            diffShortStat = GitSummary.describe(DiffStat(diff: newDiff))
            cachedDiffShortStat = GitSummary.describe(stagedStatistics)
            status = snapshot.status
            cachedDiffRaw = snapshot.staged
            diffRaw = snapshot.unstaged
            cachedDiff = newCachedDiff
            cachedExpandableFileDiffs = newCachedDiff.fileDiffs.withExpansionState(from: cachedExpandableFileDiffs, defaultIsExpanded: fileExpansion.isExpanded)
            diff = newDiff
            expandableFileDiffs = newDiff.fileDiffs.withExpansionState(from: expandableFileDiffs, defaultIsExpanded: fileExpansion.isExpanded)
            cachedDiffStat = stagedStatistics
            updateChangesError = nil
            imageDiffRefreshID = request
            Task {
                if commitMessage.isEmpty,
                   let message = try? await DefaultMergeCommitMessage(directory: folder.url).get() {
                    commitMessage = message
                }
            }
        } catch {
            guard request == updateGeneration, !Task.isCancelled else { return }
            updateChangesError = error
        }
    }

    private func restorePatch(_ newDiff: Diff) {
        Task {
            do {
                try await IndexStaging.apply(newDiff.indexSelection(staging: false), staging: false, in: folder.url)
                await updateChanges()
            } catch {
                self.error = error
            }
        }
    }

    private func addPatch(_ newDiff: Diff) {
        Task {
            do {
                try await IndexStaging.apply(newDiff.indexSelection(staging: true), staging: true, in: folder.url)
                await updateChanges()
            } catch {
                self.error = error
            }
        }
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
