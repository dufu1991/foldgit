import FoldGitCore
import SwiftUI

extension EnvironmentValues {
    @Entry var folder: URL?
    @Entry var expandAllFiles: UUID?
    @Entry var collapseAllFiles: UUID?
    @Entry var openWorktree = OpenWorktreeAction { _ in }
    @Entry var worktreeVisibility = WorktreeVisibility()
    @Entry var openCommandLog: OpenCommandLogAction?
    @Entry var toggleCommandLog = ToggleCommandLogAction { }
}

struct OpenCommandLogAction {
    let handler: (UUID) -> Void
    func callAsFunction(_ id: UUID) { handler(id) }
}

struct ToggleCommandLogAction {
    let handler: () -> Void
    func callAsFunction() { handler() }
}

struct OpenWorktreeAction {
    let handler: (URL) -> Void
    func callAsFunction(_ url: URL) { handler(url) }
}
