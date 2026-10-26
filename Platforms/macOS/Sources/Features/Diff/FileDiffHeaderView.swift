import FoldGitCore
import SwiftUI

struct FileDiffHeaderView: View {
    @Binding var isExpanded: Bool
    var fileDiff: FileDiff
    var leadingActionImageSystemName: String?
    var leadingActionHelp: String?
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
                    .padding(.leading, 3)
                    .padding(.vertical, 8)
                    .padding(.trailing, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.textBackgroundColor).opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
            } else {
                headerContent
                    .padding(.leading, 3)
                    .padding(.trailing, 12)
                    .padding(.vertical, 8)
                    .background(Color(NSColor.textBackgroundColor).opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var headerContent: some View {
        HStack(spacing: 4) {
            if let leadingActionImageSystemName {
                Button {
                    onLeadingAction?()
                } label: {
                    Image(systemName: leadingActionImageSystemName)
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(leadingActionHelp ?? "")
                .accessibilityLabel(Text(verbatim: leadingActionHelp ?? ""))
                .disabled(onLeadingAction == nil)
            }

            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(expansionTitle)
            .accessibilityLabel(Text(verbatim: expansionTitle))

            FileNameView(fileDiff: fileDiff)
        }
    }
}
