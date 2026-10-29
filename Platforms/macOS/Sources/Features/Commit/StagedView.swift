import FoldGitCore
import SwiftUI

struct StagedView: View {
    @Binding var fileDiffs: [ExpandableModel<FileDiff>]
    var status: String
    var onSelectFileDiff: ((FileDiff) -> Void)?
    var onSelectChunk: ((FileDiff, Chunk) -> Void)?
    var layout = ChangeFileLayout.list
    var tree = ChangeFileTree()
    @Binding var collapsedDirectories: Set<String>
    @Binding var isExpanded: Bool
    var onSelectDirectory: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if fileDiffs.isEmpty {
                SectionHeader(title: "Staged Changes", fileCount: fileDiffs.count, callout: String(localized: "No Changes"))
                    .padding(.leading, 3)
            } else {
                DisclosureGroup(isExpanded: $isExpanded) {
                    EmptyView()
                } label: {
                    SectionHeader(title: "Staged Changes", fileCount: fileDiffs.count, callout: status)
                        .padding(.leading, 3)
                }
                .fixedSize(horizontal: false, vertical: true)

                if isExpanded {
                    ScrollView {
                        StageFileDiffsView(
                            expandableFileDiffs: $fileDiffs,
                            selectButtonImageSystemName: "minus",
                            selectFileButtonHelp: String(localized: "Unstage This File"),
                            selectButtonHelp: String(localized: "Unstage This Hunk"),
                            onSelectFileDiff: onSelectFileDiff,
                            onSelectChunk: onSelectChunk,
                            layout: layout,
                            tree: tree,
                            collapsedDirectories: $collapsedDirectories,
                            onSelectDirectory: onSelectDirectory,
                            selectDirectoryButtonHelp: String(localized: "Unstage This Directory")
                        )
                        .environment(\.imageDiffContext, .staged)
                        .padding(.leading, 4)
                        .padding(.top)
                    }
                    .scrollEdgeEffectStyle(.hard, for: .vertical)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
