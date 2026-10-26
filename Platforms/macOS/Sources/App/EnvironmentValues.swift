import FoldGitCore
import FoundationModels
import SwiftUI

extension EnvironmentValues {
    @Entry var folder: URL?
    @Entry var expandAllFiles: UUID?
    @Entry var collapseAllFiles: UUID?
    @Entry var openWorktree = OpenWorktreeAction { _ in }
    @Entry var worktreeVisibility = WorktreeVisibility()
    @Entry var systemLanguageModelAvailability = IntelligenceClient().availability
}

struct OpenWorktreeAction {
    let handler: (URL) -> Void
    func callAsFunction(_ url: URL) { handler(url) }
}
