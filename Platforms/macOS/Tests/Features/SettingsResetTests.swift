import AppKit
import Foundation
import SwiftUI
import Testing
import XCTest
@testable import FoldGit

@MainActor
struct SettingsResetTests {
    private func withDefaults(_ body: (UserDefaults, String) throws -> Void) rethrows {
        let name = "FoldGit.SettingsResetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults, name)
    }

    @Test func resetRestoresEveryPreferenceAndKeepsWorkspaceData() throws {
        try withDefaults { defaults, name in
            for key in SettingsReset.preferenceKeys { defaults.set("custom", forKey: key.rawValue) }
            InterfaceLanguage.english.apply(to: defaults)
            let workspaceValues: [String: Any] = [
                PreferenceKey.folder.rawValue: Data("repository groups".utf8),
                PreferenceKey.folderBeforeLogicalGroups.rawValue: Data("original groups".utf8),
                PreferenceKey.repositoryDisplayNames.rawValue: Data("custom names".utf8),
                PreferenceKey.sidebarDates.rawValue: Data("usage dates".utf8),
                PreferenceKey.searchTokenHisrtory.rawValue: Data("search history".utf8),
                PreferenceKey.lastSelectedRepository.rawValue: "/projects/FoldGit",
                PreferenceKey.openInRecentApplications.rawValue: ["com.example.Editor"],
                "foldgit.preferences.imported.v1": true,
                "NSWindow Frame FoldGitSettingsWindow": "original frame",
            ]
            for (key, value) in workspaceValues { defaults.set(value, forKey: key) }
            var loginRegistrations = 0
            try SettingsReset.restore(in: defaults) { loginRegistrations += 1 }
            #expect(loginRegistrations == 1)
            let domain = defaults.persistentDomain(forName: name)!
            for key in SettingsReset.preferenceKeys { #expect(domain[key.rawValue] == nil) }
            #expect(domain["AppleLanguages"] == nil)
            #expect(defaults.bool(forKey: PreferenceKey.launchAtLoginConfigured.rawValue))
            for (key, value) in workspaceValues {
                #expect(NSDictionary(dictionary: [key: domain[key]!]).isEqual(to: [key: value]))
            }
            #expect(AppPreferences.restoresSession(in: defaults))
            #expect(AppPreferences.codeFontSize(in: defaults) == 12)
            #expect(AppStorage(wrappedValue: AppPreferences.defaultToolbarLabelStyle, PreferenceKey.toolbarLabelStyle.rawValue, store: defaults).wrappedValue == .titleAndIcon)
            #expect(AppStorage(wrappedValue: true, PreferenceKey.showCommitGraph.rawValue, store: defaults).wrappedValue)
            #expect(AppStorage(wrappedValue: PreferenceDefaults.showWorktreeInformation, PreferenceKey.showWorktreeInformation.rawValue, store: defaults).wrappedValue)
            let worktreePreferences = RepositoryWorktreePreferences.decode(AppStorage(wrappedValue: PreferenceDefaults.repositoryWorktreeVisibility, PreferenceKey.repositoryWorktreeVisibility.rawValue, store: defaults).wrappedValue)
            #expect(!worktreePreferences.isEnabled(for: URL(fileURLWithPath: "/projects/FoldGit"), global: true))
            #expect(!AppStorage(wrappedValue: false, PreferenceKey.wrapLongLines.rawValue, store: defaults).wrappedValue)
            #expect(AppStorage(wrappedValue: DiffLayout.automatic, PreferenceKey.diffLayout.rawValue, store: defaults).wrappedValue == .automatic)
            #expect(AppStorage(wrappedValue: DiffFileExpansion.expanded, PreferenceKey.diffFileExpansion.rawValue, store: defaults).wrappedValue == .expanded)
            #expect(AppStorage(wrappedValue: SidebarSort.manual, PreferenceKey.sidebarSort.rawValue, store: defaults).wrappedValue == .manual)
        }
    }

    @Test func registrationFailureDoesNotPartiallyResetSettings() {
        enum RegistrationError: Error { case unavailable }
        withDefaults { defaults, name in
            defaults.set(18.0, forKey: PreferenceKey.codeFontSize.rawValue)
            defaults.set(InterfaceLanguage.english.rawValue, forKey: PreferenceKey.interfaceLanguage.rawValue)
            InterfaceLanguage.english.apply(to: defaults)
            let original = defaults.persistentDomain(forName: name)!
            #expect(throws: RegistrationError.self) {
                try SettingsReset.restore(in: defaults) { throw RegistrationError.unavailable }
            }
            #expect(NSDictionary(dictionary: defaults.persistentDomain(forName: name)!).isEqual(to: original))
        }
    }

    @Test func toolbarAndSnippetsReturnToDefaultsAfterSavedCustomizations() async throws {
        let name = "FoldGit.ResetLiveToolbar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let toolbar = AppStorage(wrappedValue: AppPreferences.defaultToolbarLabelStyle, PreferenceKey.toolbarLabelStyle.rawValue, store: defaults)
        toolbar.wrappedValue = .iconOnly
        let entries = [CommitMessageSnippetEntry(text: "custom", isFavorite: true)]
        defaults.set(try JSONEncoder().encode(entries), forKey: PreferenceKey.commitMessageSnippetEntries.rawValue)
        defaults.set(try JSONEncoder().encode(["legacy custom"]), forKey: PreferenceKey.commitMessageSnippet.rawValue)
        var visibleStyle: ToolbarLabelStyle?
        let view = NSHostingView(rootView: ToolbarPreferenceProbe(defaults: defaults) { visibleStyle = $0 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(visibleStyle == .iconOnly)
        try SettingsReset.restore(in: defaults, ensureLoginAtDefault: {})
        try await Task.sleep(for: .milliseconds(100))
        #expect(visibleStyle == .titleAndIcon)
        let data = AppStorage(wrappedValue: PreferenceDefaults.commitMessageSnippetEntries, PreferenceKey.commitMessageSnippetEntries.rawValue, store: defaults).wrappedValue
        let restored = CommitMessageSnippetEntry.decode(data)
        #expect(restored.map(\.text) == CommitMessageSnippet.defaultPrefixes)
        #expect(restored.filter(\.isFavorite).map(\.text) == ["fix: ", "feat: ", "docs: "])
        PreferenceDefaults.migrateCommitMessageSnippetEntries(in: defaults)
        #expect(defaults.object(forKey: PreferenceKey.commitMessageSnippetEntries.rawValue) == nil)
    }

    @Test func allRepositoryFetchIntervalsAndCustomApplicationsAreCleared() throws {
        try withDefaults { defaults, _ in
            defaults.set(["/projects/a": 5, "/projects/b": 60], forKey: PreferenceKey.projectAutoFetch.rawValue)
            defaults.set(["com.example.Editor"], forKey: PreferenceKey.openInPinnedApplications.rawValue)
            defaults.set(["/Applications/Custom.app"], forKey: PreferenceKey.openInCustomApplications.rawValue)
            try SettingsReset.restore(in: defaults, ensureLoginAtDefault: {})
            #expect(defaults.dictionary(forKey: PreferenceKey.projectAutoFetch.rawValue) == nil)
            #expect(OpenInStore(defaults: defaults).pinnedIDs.isEmpty)
            #expect(defaults.stringArray(forKey: PreferenceKey.openInCustomApplications.rawValue) == nil)
        }
    }

    @Test func confirmationShowsEveryCategoryAndAllDefaultSnippets() {
        let groups = SettingsReset.groups
        #expect(groups.map(\.id) == ["general", "appearance", "comparison", "snippets", "repositories", "applications", "sidebar"])
        let snippets = groups.first { $0.id == "snippets" }!
        for prefix in CommitMessageSnippet.defaultPrefixes {
            #expect(snippets.items[0].value.contains(prefix.trimmingCharacters(in: .whitespaces)))
        }
        #expect(snippets.items[1].value == "fix:  feat:  docs:")
        #expect(groups.flatMap(\.items).filter { $0.keys.contains(.codeFontSize) }.first?.value == String(localized: "\(12) pt"))
    }
}

private struct ToolbarPreferenceProbe: View {
    @AppStorage private var style: ToolbarLabelStyle
    let onChange: (ToolbarLabelStyle) -> Void

    init(defaults: UserDefaults, onChange: @escaping (ToolbarLabelStyle) -> Void) {
        _style = AppStorage(wrappedValue: AppPreferences.defaultToolbarLabelStyle, PreferenceKey.toolbarLabelStyle.rawValue, store: defaults)
        self.onChange = onChange
    }

    var body: some View {
        Color.clear.onChange(of: style, initial: true) { onChange(style) }
    }
}

final class RestoreDefaultsPresentationTests: XCTestCase {
    @MainActor
    func testConfirmationFitsWindowAndDoesNotResetOnPresentation() async throws {
        for dark in [false, true] {
            var resets = 0
            let view = NSHostingView(rootView: RestoreDefaultsSheet(restore: { resets += 1 })
                .background(Color(nsColor: .windowBackgroundColor)))
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let size = view.fittingSize
            XCTAssertEqual(size.width, 600, accuracy: 1)
            XCTAssertEqual(size.height, 620, accuracy: 1)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderBack(nil)
            defer { window.close() }
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            window.displayIfNeeded()
            XCTAssertEqual(resets, 0)
            let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "restore-defaults-\(dark ? "dark" : "light")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
