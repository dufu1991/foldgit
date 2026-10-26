import FoldGitCore
import SwiftUI

struct CommitDetailBottomBar: View {
    var commit: Commit
    var folder: WorkspaceEntry
    @Binding var fileDiffs: [ExpandableModel<FileDiff>]
    @State private var shortstat = ""

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                displayControls
                statistics
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 8) {
                displayControls
                statistics
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(minHeight: 40)
        .task(id: commit) {
            let output = (try? await GitRuntime.run(GitShowShortstat(directory: folder.url, object: commit.hash))) ?? ""
            guard !Task.isCancelled else { return }
            shortstat = output
        }
    }

    private var displayControls: some View {
        DiffDisplayControls(showsFileControls: !fileDiffs.isEmpty, onExpandAll: {
            fileDiffs = fileDiffs.map { ExpandableModel(isExpanded: true, model: $0.model) }
        }, onCollapseAll: {
            fileDiffs = fileDiffs.map { ExpandableModel(isExpanded: false, model: $0.model) }
        })
    }

    private var statistics: some View {
        Text(GitSummary.shortStat(shortstat))
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
