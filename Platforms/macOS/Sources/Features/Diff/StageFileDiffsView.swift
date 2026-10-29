import FoldGitCore
import SwiftUI

struct StageFileDiffsView: View {
    @Binding var expandableFileDiffs: [ExpandableModel<FileDiff>]
    var selectButtonImageSystemName: String
    var selectFileButtonHelp: String
    var selectButtonHelp: String
    var onSelectFileDiff: ((FileDiff) -> Void)?
    var onSelectChunk: ((FileDiff, Chunk) -> Void)?
    var layout = ChangeFileLayout.list
    var tree = ChangeFileTree()
    @Binding var collapsedDirectories: Set<String>
    var onSelectDirectory: ((String) -> Void)? = nil
    var selectDirectoryButtonHelp = String(localized: "Stage This Directory")

    var body: some View {
        let index = ExpandableFileDiffIndex(expandableFileDiffs)
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            if layout == .tree {
                ChangeFileTreeRows(tree: tree, collapsedDirectories: $collapsedDirectories,
                                   actionImageSystemName: selectButtonImageSystemName,
                                   actionHelp: selectDirectoryButtonHelp,
                                   onSelectDirectory: onSelectDirectory) { row in
                    if let id = row.fileID, let offset = index.offset(of: id) {
                        fileView(index.files[offset], sourceIndex: offset, treeDepth: row.depth)
                    }
                }
            } else {
                ForEach(Array(index.files.enumerated()), id: \.element.model.id) { offset, file in
                    fileView(file, sourceIndex: offset)
                }
            }
        }
        .font(Font.system(.body, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fileView(_ original: ExpandableModel<FileDiff>, sourceIndex: Int, treeDepth: Int? = nil) -> some View {
        StageFileDiffView(
            expandableFileDiff: $expandableFileDiffs.element(original, near: sourceIndex),
            selectButtonImageSystemName: selectButtonImageSystemName,
            selectFileButtonHelp: selectFileButtonHelp,
            selectButtonHelp: selectButtonHelp,
            onSelectFileDiff: onSelectFileDiff,
            onSelectChunk: onSelectChunk,
            treeDepth: treeDepth
        )
    }
}
