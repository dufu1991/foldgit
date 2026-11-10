import FoldGitCore
import SwiftUI

struct FileDiffView: View {
    @Environment(\.diffFileContext) private var diffFileContext
    @Binding var expandableFileDiff: ExpandableModel<FileDiff>
    var treeDepth: Int? = nil

    var body: some View {
        DiffFileSection {
            if expandableFileDiff.isExpanded {
                if let diffFileContext,
                   DiffImage.supports(path: expandableFileDiff.model.fromFilePath) || DiffImage.supports(path: expandableFileDiff.model.toFilePath) {
                    ImageDiffView(fileDiff: expandableFileDiff.model, context: diffFileContext)
                } else {
                    DiffSyntaxContent(file: expandableFileDiff.model) { colors in
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(expandableFileDiff.model.chunks) { chunk in
                                ChunkView(chunk: chunk, syntaxColors: colors)
                            }
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 12)
                    }
                }
            }
        } header: {
            FileDiffHeaderView(
                isExpanded: $expandableFileDiff.isExpanded,
                fileDiff: expandableFileDiff.model,
                treeDepth: treeDepth
            )
        } footer: {
            if expandableFileDiff.isExpanded { FileDiffDivider() }
        }
    }
}

/// Eager geometry keeps the scroll document stable; pinning changes only the header's drawing position.
struct DiffFileSection<Content: View, Header: View, Footer: View>: View {
    @State private var coordinateSpaceID = UUID()
    @ViewBuilder var content: () -> Content
    @ViewBuilder var header: () -> Header
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        let coordinateSpaceID = coordinateSpaceID
        VStack(alignment: .leading, spacing: 0) {
            header()
                .visualEffect { effect, geometry in
                    let viewport = geometry.bounds(of: .scrollView(axis: .vertical))
                    let section = geometry.bounds(of: .named(coordinateSpaceID))
                    let offset = min(max(0, viewport?.minY ?? 0),
                                     max(0, (section?.maxY ?? geometry.size.height) - geometry.size.height))
                    return effect.offset(y: offset)
                }
                .zIndex(1)
            content()
            footer()
        }
        .coordinateSpace(name: coordinateSpaceID)
    }
}
