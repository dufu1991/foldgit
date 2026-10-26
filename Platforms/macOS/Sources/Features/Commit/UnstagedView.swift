import FoldGitCore
import SwiftUI

struct UnstagedView: View {
    @Binding var fileDiffs: [ExpandableModel<FileDiff>]
    var status: String
    var untrackedFiles: [String]
    var onSelectFileDiff: ((FileDiff) -> Void)?
    var onSelectChunk: ((FileDiff, Chunk) -> Void)?
    var onSelectUntrackedFile: ((String) -> Void)?
    @State private var isExpanded = true
    @State private var isUntrackedExpanded = false

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
                onSelectChunk: onSelectChunk
            )
            .environment(\.imageDiffContext, .unstaged)
            .padding(.leading, 4)
            .padding(.top)

            if !untrackedFiles.isEmpty {
                DisclosureGroup(isExpanded: $isUntrackedExpanded) {
                    ForEach(untrackedFiles, id: \.self) { file in
                        if DiffImage.supports(path: file) {
                            DisclosureGroup {
                                ImageDiffView(untrackedPath: file)
                            } label: {
                                untrackedFileRow(file)
                            }
                        } else {
                            untrackedFileRow(file)
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

    private func untrackedFileRow(_ file: String) -> some View {
        HStack {
            Button {
                onSelectUntrackedFile?(file)
            } label: {
                Image(systemName: "plus")
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Stage This File")
            .accessibilityLabel(Text("Stage This File"))
            .disabled(onSelectUntrackedFile == nil)
            Text(file)
                .fontWeight(.bold)
            OpenFileButton(filePath: file)
            Spacer()
        }
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
            }
        )
    }
}
