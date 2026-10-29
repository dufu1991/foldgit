import FoldGitCore
import SwiftUI

extension Image {
    static let gitBranch = Image("git.branch")
}

extension GitRef {
    var icon: Image {
        kind == .tag ? Image(systemName: "tag") : .gitBranch
    }
}
