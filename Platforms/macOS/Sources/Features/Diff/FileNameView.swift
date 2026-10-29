import FoldGitCore
import SwiftUI

struct FileNameView: View {
    @Environment(\.colorScheme) private var colorScheme
    var fileDiff: FileDiff
    var showsTreeName = false

    var body: some View {
        HStack {
            FileChangeBadge(change: fileDiff.change)
            Image(nsImage: FileIconTheme.bundled.image(filePath: fileDiff.toFilePath, isDark: colorScheme == .dark))
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(verbatim: showsTreeName ? fileDiff.changeTreeTitle : fileDiff.filePathDisplay)
                .fontWeight(.bold)
                .font(Font.system(.body, design: .default))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(fileDiff.header + "\n" + (fileDiff.extendedHeaderLines + fileDiff.fromFileToFileLines).joined(separator: "\n"))
        }
    }
}
