import FoldGitCore
import SwiftUI

struct FileNameView: View {
    @Environment(\.colorScheme) private var colorScheme
    var fileDiff: FileDiff

    var body: some View {
        HStack {
            FileChangeBadge(change: fileDiff.change)
            Image(nsImage: FileIconTheme.bundled.image(filePath: fileDiff.toFilePath, isDark: colorScheme == .dark))
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            Text(fileDiff.filePathDisplay)
                .fontWeight(.bold)
                .font(Font.system(.body, design: .default))
                .help(fileDiff.header + "\n" + (fileDiff.extendedHeaderLines + fileDiff.fromFileToFileLines).joined(separator: "\n"))
            OpenFileButton(filePath: fileDiff.toFilePath)
        }
    }
}
