import FoldGitCore
import SwiftUI

struct CommitDetailBottomBar: View {
    var commit: Commit
    var folder: WorkspaceEntry
    @Binding var fileDiffs: [ExpandableModel<FileDiff>]
    var changeFileLayout: Binding<ChangeFileLayout>? = nil
    var onExpandDirectories: (() -> Void)? = nil
    var onCollapseDirectories: (() -> Void)? = nil
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
        DiffDisplayControls(showsFileControls: !fileDiffs.isEmpty,
                            changeFileLayout: fileDiffs.isEmpty ? nil : changeFileLayout,
                            onExpandDirectories: onExpandDirectories,
                            onCollapseDirectories: onCollapseDirectories,
                            onExpandAll: { setExpansion(true) },
                            onCollapseAll: { setExpansion(false) })
    }

    private func setExpansion(_ isExpanded: Bool) {
        fileDiffs = fileDiffs.settingExpansion(isExpanded)
    }

    private var statistics: some View {
        Text(GitSummary.shortStat(shortstat))
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
