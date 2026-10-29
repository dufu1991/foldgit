import FoldGitCore
import SwiftUI

struct StageFileDiffView: View {
    @Environment(\.imageDiffContext) private var imageDiffContext
    @Binding var expandableFileDiff: ExpandableModel<FileDiff>
    var fileDiff: FileDiff {
        expandableFileDiff.model
    }
    var selectButtonImageSystemName: String
    var selectFileButtonHelp: String
    var selectButtonHelp: String
    var onSelectFileDiff: ((FileDiff) -> Void)?
    var onSelectChunk: ((FileDiff, Chunk) -> Void)?
    var treeDepth: Int?

    var body: some View {
        Section {
            if expandableFileDiff.isExpanded {
                if let imageDiffContext,
                   DiffImage.supports(path: fileDiff.fromFilePath) || DiffImage.supports(path: fileDiff.toFilePath) {
                    ImageDiffView(fileDiff: fileDiff, context: imageDiffContext)
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(fileDiff.chunks) { chunk in
                            HStack(spacing: 0) {
                                ChunkView(chunk: chunk, filePath: fileDiff.toFilePath)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Spacer(minLength: 0)
                                Button {
                                    onSelectChunk?(fileDiff, chunk)
                                } label: {
                                    Image(systemName: selectButtonImageSystemName)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 22, height: 22)
                                }
                                .buttonStyle(.plain)
                                .controlSize(.small)
                                .help(selectButtonHelp)
                                .accessibilityLabel(Text(verbatim: selectButtonHelp))
                                .padding(.vertical)
                                .disabled(onSelectChunk == nil)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    if fileDiff.chunks.isEmpty {
                        HStack {
                            Button {
                                onSelectFileDiff?(fileDiff)
                            } label: {
                                Image(systemName: selectButtonImageSystemName)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(.plain)
                            .controlSize(.small)
                            .help(selectFileButtonHelp)
                            .accessibilityLabel(Text(verbatim: selectFileButtonHelp))
                            .disabled(onSelectFileDiff == nil)
                            .padding(.trailing, 8)
                            VStack(alignment: .leading) {
                                Text(fileDiff.header)
                                Text(fileDiff.extendedHeaderLines.joined(separator: "\n"))
                                Text(fileDiff.fromFileToFileLines.joined(separator: "\n"))
                            }
                            Spacer()
                        }
                    }
                }
            }
        } header: {
            FileDiffHeaderView(
                isExpanded: $expandableFileDiff.isExpanded,
                fileDiff: fileDiff,
                leadingActionImageSystemName: selectButtonImageSystemName,
                leadingActionHelp: selectFileButtonHelp,
                treeDepth: treeDepth
            ) {
                onSelectFileDiff?(fileDiff)
            }
        } footer: {
            if expandableFileDiff.isExpanded { FileDiffDivider() }
        }
    }
}
