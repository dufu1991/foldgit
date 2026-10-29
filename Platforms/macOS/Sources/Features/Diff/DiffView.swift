import FoldGitCore
import SwiftUI

struct DiffView: View {
    @Binding var commits: [Commit]
    @Binding var filesChanged: [ExpandableModel<FileDiff>]
    @Binding var tab: Int
    var layout = ChangeFileLayout.list
    var tree = ChangeFileTree()
    var collapsedDirectories: Binding<Set<String>> = .constant([])

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DiffTabView(tab: $tab)
                .padding(.top)
            if tab == 0 {
                DiffCommitListView(commits: commits)
                    .padding(.vertical)
            }
            if tab == 1 {
                FileDiffsView(expandableFileDiffs: $filesChanged, layout: layout,
                              tree: tree, collapsedDirectories: collapsedDirectories)
            }
        }
    }
}
