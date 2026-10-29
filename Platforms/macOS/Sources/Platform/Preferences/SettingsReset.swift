import Foundation
import ServiceManagement

extension Notification.Name {
    static let settingsDidRestoreDefaults = Notification.Name("FoldGit.settingsDidRestoreDefaults")
}

@MainActor
enum SettingsReset {
    struct Item: Identifiable {
        let id: String
        let title: String
        let value: String
        var keys: [PreferenceKey] = []
    }

    struct Group: Identifiable {
        let id: String
        let title: String
        let items: [Item]
    }

    /// The confirmation and reset share this list so every reset preference is disclosed.
    static var groups: [Group] {
        let on = String(localized: "On")
        let off = String(localized: "Off")
        let automatic = String(localized: "Automatic")
        let none = String(localized: "None")
        let snippets = CommitMessageSnippetEntry.defaults
        let snippetText = { (entries: [CommitMessageSnippetEntry]) in
            entries.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: "  ")
        }
        return [
            Group(id: "general", title: String(localized: "General"), items: [
                Item(id: "language", title: String(localized: "Interface Language"), value: automatic, keys: [.interfaceLanguage]),
                Item(id: "login", title: String(localized: "Launch at Login"), value: on),
                Item(id: "session", title: String(localized: "Restore Previous Repository and Window"), value: on, keys: [.restoreSession]),
                Item(id: "quit", title: String(localized: "Quit When the Last Window Closes"), value: off, keys: [.quitAfterLastWindow]),
            ]),
            Group(id: "appearance", title: String(localized: "Appearance"), items: [
                Item(id: "appearance", title: String(localized: "Color Scheme"), value: automatic, keys: [.appAppearance]),
                Item(id: "toolbar", title: String(localized: "Toolbar Display"), value: String(localized: "Icons and Text"), keys: [.toolbarLabelStyle]),
            ]),
            Group(id: "comparison", title: String(localized: "History and Diffs"), items: [
                Item(id: "graph", title: String(localized: "Show Commit Graph"), value: on, keys: [.showCommitGraph]),
                Item(id: "historyScope", title: String(localized: "History Scope"), value: String(localized: "Current Branch"), keys: [.repositoryHistoryScopes]),
                Item(id: "layout", title: String(localized: "Diff Layout"), value: automatic, keys: [.diffLayout]),
                Item(id: "expansion", title: String(localized: "Default File Expansion"), value: AppPreferences.defaultDiffFileExpansion.title, keys: [.diffFileExpansion]),
                Item(id: "changeFiles", title: String(localized: "Changed File Display"), value: AppPreferences.defaultChangeFileLayout.title, keys: [.changeFileLayout]),
                Item(id: "font", title: String(localized: "Code Font Size"), value: String(localized: "\(Int(AppPreferences.defaultCodeFontSize)) pt"), keys: [.codeFontSize]),
                Item(id: "wrap", title: String(localized: "Wrap Long Lines"), value: off, keys: [.wrapLongLines]),
            ]),
            Group(id: "snippets", title: String(localized: "Commit Messages"), items: [
                Item(id: "snippets", title: String(localized: "Commit Message Snippets"), value: snippetText(snippets),
                     keys: [.commitMessageSnippet, .commitMessageSnippetEntries]),
                Item(id: "favorites", title: String(localized: "Show in Quick Input"), value: snippetText(snippets.filter(\.isFavorite))),
            ]),
            Group(id: "repositories", title: String(localized: "Repositories"), items: [
                Item(id: "worktrees", title: String(localized: "Enable Worktrees"), value: on, keys: [.showWorktreeInformation]),
                Item(id: "worktreeOverrides", title: String(localized: "Repository Worktrees"), value: String(localized: "Off for All Repositories"), keys: [.repositoryWorktreeVisibility]),
                Item(id: "fetch", title: String(localized: "Automatic Fetch"), value: String(localized: "Off for All Repositories"), keys: [.projectAutoFetch]),
            ]),
            Group(id: "applications", title: String(localized: "External Applications"), items: [
                Item(id: "pinned", title: String(localized: "Pinned Applications"), value: none, keys: [.openInPinnedApplications]),
                Item(id: "custom", title: String(localized: "Custom Applications"), value: none, keys: [.openInCustomApplications]),
            ]),
            Group(id: "sidebar", title: String(localized: "Sidebar"), items: [
                Item(id: "sort", title: String(localized: "Sort Repositories"), value: String(localized: "Manual Order"), keys: [.sidebarSort]),
                Item(id: "direction", title: String(localized: "Sort Direction"), value: String(localized: "Ascending"), keys: [.sidebarSortAscending]),
            ]),
        ]
    }

    static var preferenceKeys: Set<PreferenceKey> {
        Set(groups.flatMap(\.items).flatMap(\.keys))
    }

    static func restore(in defaults: UserDefaults = .standard, ensureLoginAtDefault: () throws -> Void = {
        let service = SMAppService.mainApp
        let status = service.status
        if status != .enabled && status != .requiresApproval { try service.register() }
    }) throws {
        // Complete the only fallible operation before changing any saved preferences.
        try ensureLoginAtDefault()
        for key in preferenceKeys { defaults.removeObject(forKey: key.rawValue) }
        InterfaceLanguage.automatic.apply(to: defaults)
        LaunchAtLoginPreferences.rememberUserChoice(in: defaults)
    }
}
