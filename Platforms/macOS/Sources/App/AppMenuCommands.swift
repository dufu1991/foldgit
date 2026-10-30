import AppKit
import FoldGitCore
import SwiftUI

enum MenuCommand: String {
    case openRepository, cloneRepository, newGroup, newWorktree, manageWorktrees, finishWorktree
    case toggleSidebar, toggleCommandLog, expandAll, collapseAll, searchCommits, revealHead, showChanges
    case expandDirectories, collapseDirectories
    case refresh, fetch, pull, push, stash, showStashes, showBranches, newBranch, renameBranch, mergeBranch, openTerminal
    case compare, showTags, newTag, checkoutCommit, revertCommit, copyCommitHash, amendCommit
    case stageAll, unstageAll, commit
    case chooseApplication, showInFinder

    /// The single source for key equivalents, shared by the menu bar and the Keyboard Shortcuts window.
    var shortcut: MenuShortcut? {
        switch self {
        case .openRepository: MenuShortcut("o")
        case .cloneRepository: MenuShortcut("n", [.command, .shift])
        case .copyCommitHash: MenuShortcut("c", [.command, .shift])
        case .searchCommits: MenuShortcut("f")
        case .toggleSidebar: MenuShortcut("s", [.command, .control])
        case .showChanges: MenuShortcut("1")
        case .revealHead: MenuShortcut("0")
        case .expandAll: MenuShortcut(.rightArrow, .option)
        case .collapseAll: MenuShortcut(.leftArrow, .option)
        case .refresh: MenuShortcut("r")
        case .fetch: MenuShortcut("f", [.command, .shift])
        case .pull: MenuShortcut("l", [.command, .shift])
        case .push: MenuShortcut("p", [.command, .shift])
        case .stash: MenuShortcut("h", [.command, .shift])
        case .showInFinder: MenuShortcut("o", [.command, .control])
        case .openTerminal: MenuShortcut("t", [.command, .control])
        case .showBranches: MenuShortcut("b")
        case .newBranch: MenuShortcut("b", [.command, .shift])
        case .newTag: MenuShortcut("t", [.command, .shift])
        case .commit: MenuShortcut(.return)
        case .stageAll: MenuShortcut("s", [.command, .shift])
        case .unstageAll: MenuShortcut("s", [.command, .option, .shift])
        default: nil
        }
    }
}

struct MenuShortcut {
    var key: KeyEquivalent
    var modifiers: EventModifiers

    init(_ key: KeyEquivalent, _ modifiers: EventModifiers = .command) {
        self.key = key
        self.modifiers = modifiers
    }

    var symbols: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case .return: return text + "↩"
        case .rightArrow: return text + "→"
        case .leftArrow: return text + "←"
        default: return text + String(key.character).uppercased()
        }
    }
}

/// Each scene publishes its own handlers so commands cannot target another window's repository.
struct MenuActions {
    var handlers: [MenuCommand: @MainActor () -> Void] = [:]
    /// Set while a text editor has focus so ⌘F stays with the editor instead of jumping to commit search.
    var isEditingText = false
    subscript(_ command: MenuCommand) -> (@MainActor () -> Void)? {
        get { handlers[command] }
        set { handlers[command] = newValue }
    }
}

struct WorkspaceMenuContext {
    var actions: MenuActions
    var recentRepositories: [WorkspaceEntry]
    var openRecent: @MainActor (URL) -> Void
}

struct RepositoryMenuContext {
    var actions: MenuActions
    var directory: URL
    var historyScope: HistoryScope
    var setHistoryScope: @MainActor (HistoryScope) -> Void
    var applications: [OpenInApplication]
    var openApplication: @MainActor (OpenInApplication) -> Void
    var isOpeningApplication: Bool
}

private struct WorkspaceMenuKey: FocusedValueKey { typealias Value = WorkspaceMenuContext }
private struct SidebarMenuKey: FocusedValueKey { typealias Value = MenuActions }
private struct RepositoryMenuKey: FocusedValueKey { typealias Value = RepositoryMenuContext }
private struct StagingMenuKey: FocusedValueKey { typealias Value = MenuActions }
private struct DiffMenuKey: FocusedValueKey { typealias Value = MenuActions }
private struct EditorMenuKey: FocusedValueKey { typealias Value = MenuActions }

extension FocusedValues {
    var workspaceMenu: WorkspaceMenuContext? {
        get { self[WorkspaceMenuKey.self] }
        set { self[WorkspaceMenuKey.self] = newValue }
    }
    var sidebarMenu: MenuActions? {
        get { self[SidebarMenuKey.self] }
        set { self[SidebarMenuKey.self] = newValue }
    }
    var repositoryMenu: RepositoryMenuContext? {
        get { self[RepositoryMenuKey.self] }
        set { self[RepositoryMenuKey.self] = newValue }
    }
    var stagingMenu: MenuActions? {
        get { self[StagingMenuKey.self] }
        set { self[StagingMenuKey.self] = newValue }
    }
    var editorMenu: MenuActions? {
        get { self[EditorMenuKey.self] }
        set { self[EditorMenuKey.self] = newValue }
    }
    var diffMenu: MenuActions? {
        get { self[DiffMenuKey.self] }
        set { self[DiffMenuKey.self] = newValue }
    }
}

struct AppMenuCommands: Commands {
    @FocusedValue(\.workspaceMenu) private var workspace
    @FocusedValue(\.sidebarMenu) private var sidebar
    @FocusedValue(\.repositoryMenu) private var repository
    @FocusedValue(\.stagingMenu) private var staging
    @FocusedValue(\.diffMenu) private var diff
    @FocusedValue(\.editorMenu) private var editor
    @AppStorage(PreferenceKey.showCommitGraph.rawValue) private var showGraph = true
    @AppStorage(PreferenceKey.diffLayout.rawValue) private var diffLayout = DiffLayout.automatic
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            command("Open Repository", .openRepository)
            command("Clone Remote Repository", .cloneRepository)
            command("New Group", .newGroup)
            Menu("Open Recent") {
                ForEach(workspace?.recentRepositories ?? [], id: \.identity) { entry in
                    Button {
                        workspace?.openRecent(entry.url)
                    } label: {
                        Text(verbatim: entry.displayName)
                    }
                    .help(entry.url.path)
                }
            }
            .disabled(workspace?.recentRepositories.isEmpty != false)
            Divider()
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            command("Search Commits", .searchCommits)
            command("Copy Commit Hash", .copyCommitHash)
        }
        CommandGroup(replacing: .sidebar) {
            command("Sidebar", .toggleSidebar)
            command("Log", .toggleCommandLog)
        }
        CommandGroup(before: .toolbar) {
            Toggle("Commit Graph", isOn: $showGraph).disabled(repository == nil)
            command("Uncommitted Changes", .showChanges)
            command("Jump to HEAD", .revealHead)
            Picker("History Scope", selection: Binding(
                get: { repository?.historyScope ?? .currentBranch },
                set: { repository?.setHistoryScope($0) }
            )) {
                Text("Current Branch").tag(HistoryScope.currentBranch)
                Text("All Commits").tag(HistoryScope.allCommits)
            }
            .disabled(repository == nil)
            Divider()
            Picker("Diff Layout", selection: $diffLayout) {
                ForEach(DiffLayout.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(repository == nil)
            if handler(.expandDirectories) != nil {
                command("Expand Directories", .expandDirectories)
                command("Collapse Directories", .collapseDirectories)
            }
            command("Expand Diffs", .expandAll)
            command("Collapse Diffs", .collapseAll)
            Divider()
        }
        CommandMenu("Repository") { repositoryCommands }
        CommandMenu("Branch") { branchCommands }
        CommandMenu("Commit") { commitCommands }
        CommandGroup(replacing: .help) {
            Link("User Guide", destination: URL(string: "https://foldgit.com/manual")!)
            Button("Keyboard Shortcuts") { openWindow(id: "keyboard-shortcuts") }
            Divider()
            Link("Project Homepage", destination: URL(string: "https://github.com/dufu1991/foldgit")!)
            Link("Send Feedback", destination: URL(string: "https://github.com/dufu1991/foldgit/issues")!)
        }
    }

    @ViewBuilder private var repositoryCommands: some View {
        command("Refresh", .refresh)
        Divider()
        command("Fetch", .fetch)
        command("Pull", .pull)
        command("Push", .push)
        Divider()
        command("Stash All Changes", .stash)
        command("Show Stashes", .showStashes)
        Menu("Worktrees") {
            command("New Worktree", .newWorktree)
            command("Manage Worktrees", .manageWorktrees)
            command("Finish Worktree", .finishWorktree)
        }
        Divider()
        command("Show in Finder", .showInFinder)
        command("Open in Terminal", .openTerminal)
        Menu("Open in") {
            ForEach(repository?.applications ?? []) { application in
                Button { repository?.openApplication(application) } label: { Text(verbatim: application.name) }
                    .disabled(repository?.isOpeningApplication == true)
            }
            Divider()
            command("Choose Application", .chooseApplication)
        }
        .disabled(repository == nil)
    }

    @ViewBuilder private var branchCommands: some View {
        command("Select Branch", .showBranches)
        command("New Branch", .newBranch)
        command("Rename Branch", .renameBranch)
        command("Merge Branch", .mergeBranch)
        Divider()
        command("Compare Branches or Tags", .compare)
        Menu("Tags") {
            command("Show Tags", .showTags)
            command("New Tag", .newTag)
        }
    }

    @ViewBuilder private var commitCommands: some View {
        command("Commit", .commit)
        command("Amend Last Commit", .amendCommit)
        Divider()
        command("Stage All", .stageAll)
        command("Unstage All", .unstageAll)
        Divider()
        command("Checkout Selected Commit", .checkoutCommit)
        command("Revert Selected Commit", .revertCommit)
    }

    private func handler(_ command: MenuCommand) -> (@MainActor () -> Void)? {
        switch command {
        case .commit, .amendCommit:
            if let editor { return editor[command] }
        case .stageAll, .unstageAll:
            return staging?[command]
        case .expandDirectories, .collapseDirectories:
            return staging?[command] ?? diff?[command]
        case .expandAll, .collapseAll:
            if let diff { return diff[command] }
        case .stash:
            if let staging { return staging[command] }
        case .showInFinder:
            guard let repository else { return nil }
            return { NSWorkspace.shared.activateFileViewerSelecting([repository.directory]) }
        default: break
        }
        for actions in [repository?.actions, sidebar, workspace?.actions] {
            if let action = actions?[command] { return action }
        }
        return nil
    }

    @ViewBuilder private func command(_ title: LocalizedStringKey, _ action: MenuCommand) -> some View {
        let button = Button(title) { handler(action)?() }
            .disabled(handler(action) == nil)
            .accessibilityIdentifier("menu-\(action.rawValue)")
        let yieldsToEditor = action == .searchCommits && editor?.isEditingText == true
        if let shortcut = action.shortcut, !yieldsToEditor {
            button.keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
        } else { button }
    }
}

struct KeyboardShortcutsView: View {
    var body: some View {
        Form {
            Section("Repository") {
                shortcut("Open Repository", .openRepository)
                shortcut("Clone Remote Repository", .cloneRepository)
                shortcut("Refresh", .refresh)
                shortcut("Fetch", .fetch)
                shortcut("Pull", .pull)
                shortcut("Push", .push)
                shortcut("Show in Finder", .showInFinder)
                shortcut("Open in Terminal", .openTerminal)
            }
            Section("Branch") {
                shortcut("Select Branch", .showBranches)
                shortcut("New Branch", .newBranch)
                shortcut("New Tag", .newTag)
            }
            Section("Commit") {
                shortcut("Commit", .commit)
                shortcut("Stage All", .stageAll)
                shortcut("Unstage All", .unstageAll)
                shortcut("Stash All Changes", .stash)
                shortcut("Copy Commit Hash", .copyCommitHash)
            }
            Section("View") {
                shortcut("Search Commits", .searchCommits)
                shortcut("Uncommitted Changes", .showChanges)
                shortcut("Jump to HEAD", .revealHead)
                shortcut("Sidebar", .toggleSidebar)
                shortcut("Expand Diffs", .expandAll)
                shortcut("Collapse Diffs", .collapseAll)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 720)
    }

    private func shortcut(_ title: LocalizedStringKey, _ command: MenuCommand) -> some View {
        LabeledContent(title) { Text(verbatim: command.shortcut?.symbols ?? "").monospaced() }
    }
}
