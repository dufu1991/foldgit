import FoldGitCore
import SwiftUI

extension EnvironmentValues {
    @Entry var folder: URL?
    @Entry var expandAllFiles: UUID?
    @Entry var collapseAllFiles: UUID?
    @Entry var openWorktree = OpenWorktreeAction { _ in }
    @Entry var worktreeVisibility = WorktreeVisibility()
}

struct OpenWorktreeAction {
    let handler: (URL) -> Void
    func callAsFunction(_ url: URL) { handler(url) }
}
