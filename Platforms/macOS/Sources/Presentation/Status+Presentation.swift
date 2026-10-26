import FoldGitCore
import Foundation

extension Status {
    var untrackedFilesShortStat: String {
        guard !untrackedFiles.isEmpty else { return "" }
        return String(localized: "\(untrackedFiles.count) untracked files")
    }
}
