import FoldGitCore
import SwiftUI

struct CommitDiffView: View {
    @AppStorage(PreferenceKey.diffFileExpansion.rawValue) private var fileExpansion = DiffFileExpansion.expanded
    @Environment(\.folder) private var folder
    var selectionLogID: String
    var subSelectionLogID: String
    var showsComparisonControls = true

    @State private var commitFirst = ""
    @State private var commitSecond = ""
    @State private var filesChanges: [ExpandableModel<FileDiff>] = []
    @State private var filesChangesIsEmpty = false
    @State private var shortstat = ""
    @State private var error: Error?

    private var imageDiffContext: ImageDiffContext {
        if commitFirst == Log.notCommitted.id {
            return ImageDiffContext(old: .revision(commitSecond), new: .workingTree)
        }
        if commitSecond == Log.notCommitted.id {
            return ImageDiffContext(old: .revision(commitFirst), new: .workingTree)
        }
        return ImageDiffContext(old: .revision(commitFirst), new: .revision(commitSecond))
    }

    var body: some View {
        ScrollView {
            if filesChangesIsEmpty {
                LazyVStack(alignment: .center) {
                    Label("No Changes", systemImage: "plusminus")
                        .foregroundStyle(.secondary)
                        .padding()
                        .padding()
                        .padding(.vertical, 40)
                }
            }
            FileDiffsView(expandableFileDiffs: $filesChanges)
                .environment(\.imageDiffContext, imageDiffContext)
                .padding(.horizontal)
        }
        .background(Color(NSColor.textBackgroundColor))
        .scrollEdgeEffectStyle(.hard, for: .vertical)
        .safeAreaBar(edge: .bottom, spacing: 0, content: {
            VStack(spacing: 0) {
                PixelDivider()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        displayControls
                        if showsComparisonControls { comparisonControls }
                        statistics
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 10) {
                        displayControls
                        if showsComparisonControls { comparisonControls }
                        statistics
                    }
                }
                .font(.callout)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            }
        })
        .onChange(of: [selectionLogID, subSelectionLogID], initial: true) { oldValue, newValue in
            commitFirst = selectionLogID
            commitSecond = subSelectionLogID
        }
        .task(id: [commitFirst, commitSecond]) {
            guard !commitFirst.isEmpty, !commitSecond.isEmpty else { return }
            if commitFirst == Log.notCommitted.id {
                await updateDiff(commitRange: commitSecond)
            } else if commitSecond == Log.notCommitted.id {
                await updateDiff(commitRange: commitFirst)
            } else {
                await updateDiff(commitRange: commitFirst + ".." + commitSecond)
            }
        }
        .errorSheet($error)
    }

    private var displayControls: some View {
        DiffDisplayControls(onExpandAll: {
            filesChanges = filesChanges.map { ExpandableModel(isExpanded: true, model: $0.model) }
        }, onCollapseAll: {
            filesChanges = filesChanges.map { ExpandableModel(isExpanded: false, model: $0.model) }
        })
    }

    private var comparisonControls: some View {
        HStack(spacing: 8) {
            Text("Diff").foregroundStyle(.secondary)
            Text(title(for: commitFirst))
                .lineLimit(1)
                .help(title(for: commitFirst))
            Text(verbatim: "→").foregroundStyle(.secondary)
            Text(title(for: commitSecond))
                .lineLimit(1)
                .help(title(for: commitSecond))
            Button("Swap the Commits") {
                let first = commitFirst
                commitFirst = commitSecond
                commitSecond = first
            }
            .fixedSize()
        }
    }

    private var statistics: some View {
        Text(shortstat)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func title(for revision: String) -> String {
        return revision == Log.notCommitted.id ? "Staged Changes" : String(revision.prefix(5))
    }

    private func updateDiff(commitRange: String) async {
        guard let folder else { return }
        filesChanges = []
        filesChangesIsEmpty = false
        shortstat = ""
        do {
            let raw = try await GitRuntime.run(
                GitDiff(directory: folder, noRenames: false, commitRange: commitRange)
            )
            let changes = try Diff(raw: raw).fileDiffs.map { ExpandableModel(isExpanded: fileExpansion.isExpanded, model: $0) }
            let stat = try await GitRuntime.run(
                GitDiff(directory: folder, noRenames: false, shortstat: true, commitRange: commitRange)
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            filesChanges = changes
            filesChangesIsEmpty = changes.isEmpty
            shortstat = stat.isEmpty ? String(localized: "No Changes") : GitSummary.shortStat(stat)
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error
        }
    }
}
