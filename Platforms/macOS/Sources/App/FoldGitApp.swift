import SwiftUI

@main
struct FoldGitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(PreferenceKey.toolbarLabelStyle.rawValue) private var toolbarLabelStyle = AppPreferences.defaultToolbarLabelStyle
    @AppStorage(PreferenceKey.restoreSession.rawValue) private var restoreSession = true
    @State private var expandAllFiles: UUID?
    @State private var collapseAllFiles: UUID?

    init() {
        guard ProcessInfo.processInfo.environment["FOLDGIT_TESTING"] != "1" else { return }
        LegacyPreferencesMigration.migrate()
        PreferenceDefaults.migrateWorkspaceGroups()
        PreferenceDefaults.migrateLegacyCommitMessageSnippets()
        PreferenceDefaults.migrateCommitMessageSnippetEntries()
        AutoFetchScheduler.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            WorkspaceScreen()
                .environment(\.expandAllFiles, expandAllFiles)
                .environment(\.collapseAllFiles, collapseAllFiles)
        }
        .windowToolbarStyle(.automatic)
        .windowToolbarLabelStyle($toolbarLabelStyle)
        .restorationBehavior(restoreSession ? .automatic : .disabled)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .appSettings) {
                Button("Settings") { SettingsWindowController.show() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(before: .toolbar) {
                Button("Expand All Files") {
                    expandAllFiles = UUID()
                }
                .keyboardShortcut(.rightArrow, modifiers: .option)
                Button("Collapse All Files") {
                    collapseAllFiles = UUID()
                }
                .keyboardShortcut(.leftArrow, modifiers: .option)
                Divider()
            }
        }
    }
}
