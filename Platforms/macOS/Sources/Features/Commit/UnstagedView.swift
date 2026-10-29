import FoldGitCore
import SwiftUI

struct UnstagedView: View {
    @Binding var fileDiffs: [ExpandableModel<FileDiff>]
    var status: String
    var untrackedFiles: [String]
    var onSelectFileDiff: ((FileDiff) -> Void)?
    var onSelectChunk: ((FileDiff, Chunk) -> Void)?
    var onSelectUntrackedFile: ((String) -> Void)?
    var layout = ChangeFileLayout.list
    var tree = ChangeFileTree()
    var untrackedTree = ChangeFileTree()
    @Binding var collapsedDirectories: Set<String>
    @Binding var collapsedUntrackedDirectories: Set<String>
    @Binding var isExpanded: Bool
    @Binding var isUntrackedExpanded: Bool
    @Binding var expandedUntrackedImages: Set<String>
    var onSelectDirectory: ((String) -> Void)? = nil

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if fileDiffs.isEmpty && untrackedFiles.isEmpty {
                LazyVStack(alignment: .center) {
                    Label("No Changes", systemImage: "plusminus")
                        .foregroundStyle(.secondary)
                        .padding()
                        .padding()
                        .padding(.bottom)
                        .padding(.trailing)
                }
            }
            StageFileDiffsView(
                expandableFileDiffs: $fileDiffs,
                selectButtonImageSystemName: "plus",
                selectFileButtonHelp: String(localized: "Stage This File"),
                selectButtonHelp: String(localized: "Stage This Hunk"),
                onSelectFileDiff: onSelectFileDiff,
                onSelectChunk: onSelectChunk,
                layout: layout,
                tree: tree,
                collapsedDirectories: $collapsedDirectories,
                onSelectDirectory: onSelectDirectory
            )
            .environment(\.imageDiffContext, .unstaged)
            .padding(.leading, 4)
            .padding(.top)

            if !untrackedFiles.isEmpty {
                DisclosureGroup(isExpanded: $isUntrackedExpanded) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if layout == .tree {
                            ChangeFileTreeRows(tree: untrackedTree, collapsedDirectories: $collapsedUntrackedDirectories,
                                               onSelectDirectory: onSelectDirectory) { row in
                                untrackedFile(row.path, treeDepth: row.depth)
                            }
                        } else {
                            ForEach(untrackedFiles, id: \.self) { file in
                                untrackedFile(file)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("Untracked Files")
                        Text(untrackedFiles.count, format: .number)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                }
                .padding(.top)
                .padding(.leading, 12)
                .padding(.trailing, 2)
                .padding(.bottom)
            }
        } label: {
            SectionHeader(title: "Unstaged Changes", fileCount: fileDiffs.count + untrackedFiles.count, callout: status)
                .padding(.leading, 3)
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func untrackedFile(_ file: String, treeDepth: Int? = nil) -> some View {
        if DiffImage.supports(path: file) {
            let expansion = Binding(
                get: { expandedUntrackedImages.contains(file) },
                set: { expanded in
                    if expanded { expandedUntrackedImages.insert(file) } else { expandedUntrackedImages.remove(file) }
                }
            )
            VStack(alignment: .leading, spacing: 0) {
                untrackedFileRow(file, treeDepth: treeDepth, imageExpansion: expansion)
                if expansion.wrappedValue { ImageDiffView(untrackedPath: file) }
            }
        } else {
            untrackedFileRow(file, treeDepth: treeDepth)
        }
    }

    private func untrackedFileRow(_ file: String, treeDepth: Int?, imageExpansion: Binding<Bool>? = nil) -> some View {
        UntrackedFileRow(path: file, onSelect: onSelectUntrackedFile) { stage in
            untrackedFileRowContent(file, treeDepth: treeDepth, imageExpansion: imageExpansion, stage: stage)
        }
    }

    private func untrackedFileRowContent(_ file: String, treeDepth: Int?, imageExpansion: Binding<Bool>?,
                                         stage: @escaping () -> Void) -> some View {
        HStack {
            Button {
                stage()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            .help("Stage This File")
            .accessibilityLabel(Text("Stage This File"))
            .disabled(onSelectUntrackedFile == nil)
            if let imageExpansion {
                Button {
                    imageExpansion.wrappedValue.toggle()
                } label: {
                    untrackedFileName(file, treeDepth: treeDepth)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .textSelection(.disabled)
                .accessibilityLabel(Text(verbatim: file))
                .accessibilityValue(imageExpansion.wrappedValue ? Text("Expanded") : Text("Collapsed"))
                .accessibilityHint(imageExpansion.wrappedValue ? Text("Collapse File") : Text("Expand File"))
                .accessibilityIdentifier("untrackedFileExpansion-" + file)
            } else {
                untrackedFileName(file, treeDepth: treeDepth)
            }
            OpenFileButton(filePath: file)
        }
        .padding(.leading, CGFloat(treeDepth ?? 0) * 16)
    }

    private func untrackedFileName(_ file: String, treeDepth: Int?) -> some View {
        Text(verbatim: treeDepth == nil ? file : (file as NSString).lastPathComponent)
            .fontWeight(.bold)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 22)
            .help(file)
    }

}

/// Keeps the untracked row's frame so staging it can launch a flight from where it sits.
private struct UntrackedFileRow<Content: View>: View {
    @Environment(\.stageFlights) private var stageFlights
    @State private var frame = StageFlightFrame()
    var path: String
    var onSelect: ((String) -> Void)?
    @ViewBuilder var content: (_ stage: @escaping () -> Void) -> Content

    var body: some View {
        content {
            guard let onSelect else { return }
            stageFlights?.launch(StageFlightItem(path: path, title: path, change: nil), from: frame.rect, leaving: .unstaged)
            onSelect(path)
        }
        .stageFlightRow(path: path, frame: frame)
    }
}

#Preview {
    @Previewable @State var fileDiffs: [ExpandableModel<FileDiff>] = []

    let raw = """
    diff --git a/GitBlamePR.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved b/GitBlamePR.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
    index ca7d6df..b9d9984 100644
    --- a/GitBlamePR.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
    +++ b/GitBlamePR.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
    @@ -24,7 +24,7 @@
     "repositoryURL": "https://github.com/onevcat/Kingfisher.git",
     "state": {
       "branch": null,
    -          "revision": "7ccfb6cefdb6180cde839310e3dbd5b2d6fefee5",
    +          "revision": "20d21b3fd7192a42851d7951453e96b41e4e1ed1",
       "version": "5.13.3"
     }
    }
    diff --git a/GitBlamePR/View/DetailFooter.swift b/GitBlamePR/View/DetailFooter.swift
    index ec290b6..46b0c19 100644
    --- a/GitBlamePR/View/DetailFooter.swift
    +++ b/GitBlamePR/View/DetailFooter.swift
    @@ -6,6 +6,7 @@
    //  Copyright © 2020 dev.aoyama. All rights reserved。
    
    +// test
    import SwiftUI
    
    struct DetailFooter: View {
    @@ -36,6 +37,9 @@ struct DetailFooter: View {
    }
    }
    
    +
    +
    +// test2
    struct DetailFooter_Previews: PreviewProvider {
    static var previews: some View {
     Group {
    diff --git a/testfile6.txt b/testfile6.txt
    new file mode 100644
    index 0000000..e69de29
    """

    let diff = try! Diff(raw: raw)
    fileDiffs = diff.fileDiffs.map { ExpandableModel(isExpanded: true, model: $0) }

    return ScrollView {
        UnstagedView(
            fileDiffs: $fileDiffs,
            status: "1 file changes",
            untrackedFiles: ["Projects/Files/Path.swift", "Projects/Files/Path1.swift"],
            onSelectFileDiff: { f in
                print(f)
            },
            onSelectChunk: { f, c in
                print(f, c)
            },
            onSelectUntrackedFile: { f in
                print(f)
            },
            collapsedDirectories: .constant([]),
            collapsedUntrackedDirectories: .constant([]),
            isExpanded: .constant(true),
            isUntrackedExpanded: .constant(false),
            expandedUntrackedImages: .constant([])
        )
    }
}
