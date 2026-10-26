import FoldGitCore
import SwiftUI

struct CommitDetailContentView: View {
    @AppStorage(PreferenceKey.diffFileExpansion.rawValue) private var fileExpansion = DiffFileExpansion.expanded
    var commit: Commit
    var folder: WorkspaceEntry
    @State private var commitDetail: CommitDetail?
    @State private var shortstat = ""
    @State private var fileDiffs: [ExpandableModel<FileDiff>] = []
    @State private var mergedIn: Commit?
    @State private var mergeCommitViewTab = 0
    @State private var mergeCommitFilesChanged: [ExpandableModel<FileDiff>] = []
    @State private var error: Error?

    var body: some View {
        ScrollView {
            CommitDetailHeaderView(commit: commit, mergedIn: $mergedIn)
            HStack {
                VStack (alignment: .leading, spacing: 0) {
                    Text(commit.title.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.title2)
                        .fontWeight(.bold)
                        .layoutPriority(1)
                        .padding(.top, 8)
                    if !commit.body.isEmpty {
                        Text(commit.body.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.body)
                            .padding(.top, 4)
                    }
                    HStack {
                        Icon(size: .medium, authorEmail: commit.authorEmail, authorInitial: String(commit.author.initial.prefix(2)))
                        Text(commit.author)
                        Divider()
                            .frame(height: 10)
                        Text(commit.authorEmail)
                        Spacer()
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(commit.authorDateDisplay)
                                .monospacedDigit()
                            if !commit.authorTimeZoneDisplay.isEmpty {
                                Text(verbatim: commit.authorTimeZoneDisplay)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                                    .help(TimeZone.current.identifier)
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityElement(children: .combine)
                    }
                    .padding(.top)
                    .padding(.top, 2)
                    .foregroundStyle(.secondary)
                    Divider()
                        .padding(.top)
                    if commit.parentHashes.count == 2 {
                        MergeCommitContentView(
                            mergeCommit: commit,
                            directoryURL: folder.url,
                            tab: $mergeCommitViewTab,
                            filesChanged: $mergeCommitFilesChanged
                        )
                    } else {
                        FileDiffsView(expandableFileDiffs: $fileDiffs)
                            .environment(\.imageDiffContext, ImageDiffContext(
                                old: commit.parentHashes.first.map { .revision($0) } ?? .absent,
                                new: .revision(commit.hash)))
                            .environment(\.folder, folder.url)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.textBackgroundColor))
        .textSelection(.enabled)
        .scrollEdgeEffectStyle(.hard, for: .vertical)
        .safeAreaBar(edge: .bottom, spacing: 0, content: {
            CommitDetailBottomBar(
                commit: commit,
                folder: folder,
                fileDiffs: bottomBarFileDiff()
            )
        })
        .task(id: commit) {
            // Selection can change quickly; a canceled load must not overwrite the newer commit.
            do {
                let detail = try await GitRuntime.run(GitShow(directory: folder.url, object: commit.hash))
                try Task.checkCancellation()
                commitDetail = detail
                let mergeCommit = try await GitRuntime.run(GitLog(
                    directory: folder.url,
                    merges: true,
                    ancestryPath: true,
                    reverse: true,
                    revisionRange: ["\(commit.hash)..HEAD"]
                )).first
                var merged: Commit?
                if let mergeCommit {
                    let mergedInCommits = try await GitRuntime.run(GitLog(
                        directory: folder.url,
                        revisionRange: ["\(mergeCommit.parentHashes[0])..\(mergeCommit.hash)"]
                    ))
                    if mergedInCommits.contains(where: { $0.hash == commit.hash }) { merged = mergeCommit }
                }
                try Task.checkCancellation()
                mergedIn = merged
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                commitDetail = nil
                mergedIn = nil
                self.error = error
            }
        }
        .onChange(of: commitDetail, { _, newValue in
            if let newValue {
                fileDiffs = newValue.diff.fileDiffs.map { .init(isExpanded: fileExpansion.isExpanded, model: $0) }
            } else {
                fileDiffs = []
            }
        })
        .errorSheet($error)
    }
    
    private func bottomBarFileDiff() -> Binding<[ExpandableModel<FileDiff>]> {
        if commit.parentHashes.count == 2 {
            return mergeCommitViewTab == 0 ? .constant([]) : $mergeCommitFilesChanged
        
        } else {
            return $fileDiffs
        }
    }

}
