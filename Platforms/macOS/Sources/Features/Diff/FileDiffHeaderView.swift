import FoldGitCore
import SwiftUI

struct FileDiffHeaderView: View {
    @Environment(\.stageFlights) private var stageFlights
    @Environment(\.stageFlightPane) private var stageFlightPane
    @State private var frame = StageFlightFrame()
    @Binding var isExpanded: Bool
    var fileDiff: FileDiff
    var leadingActionImageSystemName: String?
    var leadingActionHelp: String?
    var treeDepth: Int?
    var onLeadingAction: (() -> Void)?

    private var hasLeadingAction: Bool {
        leadingActionImageSystemName != nil
    }

    private var expansionTitle: String {
        isExpanded ? String(localized: "Collapse File") : String(localized: "Expand File")
    }

    var body: some View {
        Group {
            if hasLeadingAction {
                headerContent
                    .padding(.leading, CGFloat(treeDepth ?? 0) * 16)
                    .padding(.leading, 3)
                    .padding(.trailing, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.textBackgroundColor).opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
                    .stageFlightRow(path: fileDiff.changeTreePath, frame: frame)
            } else {
                headerContent
                    .padding(.leading, CGFloat(treeDepth ?? 0) * 16 + 3)
                    .padding(.trailing, 12)
                    .background(Color(NSColor.textBackgroundColor).opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var headerContent: some View {
        HStack(spacing: 4) {
            if let leadingActionImageSystemName {
                Button {
                    if let onLeadingAction {
                        if let stageFlightPane {
                            stageFlights?.launch(StageFlightItem(path: fileDiff.changeTreePath,
                                                                 title: fileDiff.filePathDisplay,
                                                                 change: fileDiff.change),
                                                 from: frame.rect, leaving: stageFlightPane)
                        }
                        onLeadingAction()
                    }
                } label: {
                    Image(systemName: leadingActionImageSystemName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .help(leadingActionHelp ?? "")
                .accessibilityLabel(Text(verbatim: leadingActionHelp ?? ""))
                .disabled(onLeadingAction == nil)
            }

            Button {
                isExpanded.toggle()
            } label: {
                FileNameView(fileDiff: fileDiff, showsTreeName: treeDepth != nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .textSelection(.disabled)
            .accessibilityLabel(Text(verbatim: fileDiff.filePathDisplay))
            .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
            .accessibilityHint(Text(verbatim: expansionTitle))
            .accessibilityIdentifier("fileDiffExpansion-" + fileDiff.changeTreePath)

            OpenFileButton(filePath: fileDiff.toFilePath)
        }
    }
}
