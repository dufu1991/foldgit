import FoldGitCore
import SwiftUI

struct MergeCommitContentView: View {
    @AppStorage(PreferenceKey.diffFileExpansion.rawValue) private var fileExpansion = AppPreferences.defaultDiffFileExpansion
    var mergeCommit: Commit
    var directoryURL: URL
    @Binding var tab: Int
    @Binding var filesChanged: [ExpandableModel<FileDiff>]
    var layout = ChangeFileLayout.list
    var tree = ChangeFileTree()
    var collapsedDirectories: Binding<Set<String>> = .constant([])
    @State private var commits: [Commit] = []
    @State private var error: Error?

    var body: some View {
        DiffView(
            commits: $commits,
            filesChanged: $filesChanged,
            tab: $tab,
            layout: layout,
            tree: tree,
            collapsedDirectories: collapsedDirectories
        )
            .environment(\.folder, directoryURL)
            .environment(\.imageDiffContext, ImageDiffContext(
                old: .revision(mergeCommit.parentHashes[0]), new: .revision(mergeCommit.hash)))
            .task(id: mergeCommit) {
                do {
                    let updatedCommits = try await Array(GitRuntime.run(GitLog(directory: directoryURL, revisionRange: ["\(mergeCommit.parentHashes[0])..\(mergeCommit.hash)"])).dropFirst())
                    let diffRaw = try await GitRuntime.run(
                        GitDiff(directory: directoryURL, noRenames: false, commitRange: mergeCommit.parentHashes[0] + ".." + mergeCommit.hash)
                    )
                    let changes = try Diff(raw: diffRaw).fileDiffs.map { ExpandableModel(isExpanded: fileExpansion.isExpanded, model: $0) }
                    try Task.checkCancellation()
                    commits = updatedCommits
                    filesChanged = changes
                } catch {
                    guard !Task.isCancelled, !(error is CancellationError) else { return }
                    self.error = error
                }
            }
            .errorSheet($error)
    }
}

#Preview {
    ScrollView {
        MergeCommitContentView(
            mergeCommit: .init(
                hash: "11fff",
                parentHashes: ["21fff", "31fff"],
                author: "FoldGit Developer",
                authorEmail: "developer@example.com",
                authorDate: "2014-10-10T13:50:40+09:00",
                title: "Hello world!",
                body: "body",
                branches: [],
                tags: []
            ),
            directoryURL: URL(string: "file:///tmp/FoldGit/")!,
            tab: .constant(0),
            filesChanged: .constant([])
        )
    }
}
