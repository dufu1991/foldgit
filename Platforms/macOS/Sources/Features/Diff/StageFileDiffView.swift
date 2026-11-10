import FoldGitCore
import SwiftUI

struct StageFileDiffView: View {
    @Environment(\.diffViewportWidth) private var viewportWidth
    @Environment(\.diffFileContext) private var diffFileContext
    @Environment(\.changeRowContext) private var changeRowContext
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
        DiffFileSection {
            if expandableFileDiff.isExpanded {
                if let diffFileContext,
                   DiffImage.supports(path: fileDiff.fromFilePath) || DiffImage.supports(path: fileDiff.toFilePath) {
                    ImageDiffView(fileDiff: fileDiff, context: diffFileContext)
                } else {
                    DiffSyntaxContent(file: fileDiff) { colors in
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(fileDiff.chunks) { chunk in
                                HStack(spacing: 0) {
                                    ChunkView(chunk: chunk, syntaxColors: colors)
                                        .environment(\.diffViewportWidth, max(0, viewportWidth - (onSelectChunk == nil ? 0 : 22)))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if let onSelectChunk {
                                        StageActionButton(systemImage: selectButtonImageSystemName, help: selectButtonHelp) {
                                            onSelectChunk(fileDiff, chunk)
                                        }
                                        .padding(.vertical)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contextMenu {
                                    if let discardChunk = changeRowContext?.discardChunk {
                                        Button("Discard This Hunk", systemImage: "arrow.uturn.backward") {
                                            discardChunk(fileDiff, chunk)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 12)
                    }
                    if fileDiff.chunks.isEmpty {
                        HStack {
                            if let onSelectFileDiff {
                                StageActionButton(systemImage: selectButtonImageSystemName, help: selectFileButtonHelp) {
                                    onSelectFileDiff(fileDiff)
                                }
                                .padding(.trailing, 8)
                            }
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
                leadingActionImageSystemName: onSelectFileDiff == nil ? nil : selectButtonImageSystemName,
                leadingActionHelp: selectFileButtonHelp,
                treeDepth: treeDepth,
                onLeadingAction: onSelectFileDiff.map { action in { action(fileDiff) } }
            )
            .changeFileRow(path: fileDiff.changeTreePath)
        } footer: {
            if expandableFileDiff.isExpanded { FileDiffDivider() }
        }
    }
}

/// The compact plus or minus button that stages or unstages one file or chunk.
struct StageActionButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .help(help)
        .accessibilityLabel(Text(verbatim: help))
    }
}
