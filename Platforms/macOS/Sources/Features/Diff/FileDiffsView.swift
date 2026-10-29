import FoldGitCore
import SwiftUI

struct FileDiffsView: View {
    @Binding var expandableFileDiffs: [ExpandableModel<FileDiff>]
    @Environment(\.expandAllFiles) private var expandAllFilesID: UUID?
    @Environment(\.collapseAllFiles) private var collapseAllFilesID: UUID?
    var layout = ChangeFileLayout.list
    var tree = ChangeFileTree()
    var collapsedDirectories: Binding<Set<String>> = .constant([])

    var body: some View {
        let index = ExpandableFileDiffIndex(expandableFileDiffs)
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            if layout == .tree {
                ChangeFileTreeRows(tree: tree, collapsedDirectories: collapsedDirectories,
                                   showsDirectoryActions: false) { row in
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
        .onChange(of: expandAllFilesID) { _, _ in
            expandableFileDiffs = expandableFileDiffs.settingExpansion(true)
        }
        .onChange(of: collapseAllFilesID) { _, _ in
            expandableFileDiffs = expandableFileDiffs.settingExpansion(false)
        }
        .font(Font.system(.body, design: .monospaced))
        .padding(.top)
    }

    private func fileView(_ original: ExpandableModel<FileDiff>, sourceIndex: Int, treeDepth: Int? = nil) -> some View {
        FileDiffView(expandableFileDiff: $expandableFileDiffs.element(original, near: sourceIndex), treeDepth: treeDepth)
            .padding(.top, 2)
    }
}

/// Looks up expandable diffs by file identity for list and tree layouts.
struct ExpandableFileDiffIndex {
    let files: [ExpandableModel<FileDiff>]
    private let offsets: [String: Int]

    init(_ files: [ExpandableModel<FileDiff>]) {
        self.files = files
        // Keep the first entry if malformed output repeats a diff header, rather than trapping.
        offsets = Dictionary(files.enumerated().map { ($0.element.model.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
    }

    func offset(of id: String) -> Int? { offsets[id] }
}

extension Binding where Value == [ExpandableModel<FileDiff>] {
    /// Lazy rows can outlive a refresh, so reads and writes resolve by file identity, never by a stale offset.
    func element(_ original: ExpandableModel<FileDiff>, near hint: Int) -> Binding<ExpandableModel<FileDiff>> {
        let id = original.model.id
        let currentIndex = { () -> Int? in
            let files = wrappedValue
            if files.indices.contains(hint), files[hint].model.id == id { return hint }
            return files.firstIndex { $0.model.id == id }
        }
        return Binding<ExpandableModel<FileDiff>>(
            get: { currentIndex().map { wrappedValue[$0] } ?? original },
            set: { updated in
                if let index = currentIndex() { wrappedValue[index] = updated }
            }
        )
    }
}
