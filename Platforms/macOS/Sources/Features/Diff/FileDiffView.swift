import FoldGitCore
import SwiftUI

struct FileDiffView: View {
    @Environment(\.imageDiffContext) private var imageDiffContext
    @Binding var expandableFileDiff: ExpandableModel<FileDiff>

    var body: some View {
        Section {
            if expandableFileDiff.isExpanded {
                if let imageDiffContext,
                   DiffImage.supports(path: expandableFileDiff.model.fromFilePath) || DiffImage.supports(path: expandableFileDiff.model.toFilePath) {
                    ImageDiffView(fileDiff: expandableFileDiff.model, context: imageDiffContext)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
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
                fileDiff: expandableFileDiff.model
            )
        } footer: {
            FileDiffDivider()
        }
    }

    private func chunksView(_ chunks: [Chunk], filePath: String) -> some View {
        ForEach(chunks) { chunk in
            ChunkView(chunk: chunk, filePath: filePath)
        }
    }
}
