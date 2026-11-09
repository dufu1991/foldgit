import FoldGitCore
import SwiftUI

struct FileDiffView: View {
    @Environment(\.imageDiffContext) private var imageDiffContext
    @Binding var expandableFileDiff: ExpandableModel<FileDiff>
    var treeDepth: Int? = nil

    var body: some View {
        DiffFileSection {
            if expandableFileDiff.isExpanded {
                if let imageDiffContext,
                   DiffImage.supports(path: expandableFileDiff.model.fromFilePath) || DiffImage.supports(path: expandableFileDiff.model.toFilePath) {
                    ImageDiffView(fileDiff: expandableFileDiff.model, context: imageDiffContext)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        chunksView(
                            expandableFileDiff.model.chunks,
                            filePath: expandableFileDiff.model.toFilePath
                        )
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

    private func chunksView(_ chunks: [Chunk], filePath: String) -> some View {
        ForEach(chunks) { chunk in
            ChunkView(chunk: chunk, filePath: filePath)
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
