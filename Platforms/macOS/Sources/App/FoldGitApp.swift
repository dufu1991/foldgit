import SwiftUI

@main
struct FoldGitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(PreferenceKey.toolbarLabelStyle.rawValue) private var toolbarLabelStyle = AppPreferences.defaultToolbarLabelStyle
    @AppStorage(PreferenceKey.restoreSession.rawValue) private var restoreSession = true

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
        }
        .windowToolbarStyle(.automatic)
        .windowToolbarLabelStyle($toolbarLabelStyle)
        .restorationBehavior(restoreSession ? .automatic : .disabled)
        .commands {
            AppMenuCommands()
            CommandGroup(replacing: .appInfo) {
                Button("About") {
                    NSApp.orderFrontStandardAboutPanel(options: [.version: ""])
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings") { SettingsWindowController.show() }
                    .keyboardShortcut(",", modifiers: .command)
                Button("Check for Updates") { UpdateChecker.shared.checkNow() }
            }
        }
        Window("Keyboard Shortcuts", id: "keyboard-shortcuts") {
            KeyboardShortcutsView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}
