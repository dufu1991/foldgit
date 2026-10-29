import AppKit
import FoldGitCore
import Foundation
import ServiceManagement
import SwiftUI
import Testing
@testable import FoldGit

struct AppPreferencesTests {
    @Test func directoryGroupsMigrateOnceWithOriginalDataBackup() throws {
        try withDefaults { defaults, _ in
            let repository = WorkspaceEntry(url: URL(fileURLWithPath: "/projects/client"))
            var group = WorkspaceEntry(url: URL(fileURLWithPath: "/projects"), children: [repository])
            group.setInfrequent(true, repository: repository)
            let original = try JSONEncoder().encode([group])
            defaults.set(original, forKey: PreferenceKey.folder.rawValue)
            PreferenceDefaults.migrateWorkspaceGroups(in: defaults)
            let migrated = try #require(defaults.data(forKey: PreferenceKey.folder.rawValue))
            let groups = try JSONDecoder().decode([WorkspaceEntry].self, from: migrated)
            #expect(groups[0].isLogicalGroup)
            #expect(groups[0].infrequentRepositories == [repository])
            #expect(defaults.data(forKey: PreferenceKey.folderBeforeLogicalGroups.rawValue) == original)
            PreferenceDefaults.migrateWorkspaceGroups(in: defaults)
            #expect(defaults.data(forKey: PreferenceKey.folder.rawValue) == migrated)
            #expect(defaults.data(forKey: PreferenceKey.folderBeforeLogicalGroups.rawValue) == original)
        }
    }

    private func withDefaults(_ body: (UserDefaults, String) throws -> Void) rethrows {
        let name = "FoldGit.AppPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults, name)
    }

    @Test func defaultSessionRestorationAndFontSize() {
        withDefaults { defaults, _ in
            #expect(AppPreferences.restoresSession(in: defaults))
            #expect(AppPreferences.codeFontSize(in: defaults) == 12)
            defaults.set(false, forKey: PreferenceKey.restoreSession.rawValue)
            #expect(!AppPreferences.restoresSession(in: defaults))
        }
    }

    @MainActor
    @Test func toolbarDefaultsToIconsAndTextAndPreservesAnExplicitChoice() {
        withDefaults { defaults, _ in
            let key = PreferenceKey.toolbarLabelStyle.rawValue
            let preference = AppStorage(wrappedValue: AppPreferences.defaultToolbarLabelStyle, key, store: defaults)
            #expect(preference.wrappedValue == .titleAndIcon)
            preference.wrappedValue = .iconOnly
            let restored = AppStorage(wrappedValue: AppPreferences.defaultToolbarLabelStyle, key, store: defaults)
            #expect(restored.wrappedValue == .iconOnly)
        }
    }

    @MainActor
    @Test func launchAtLoginIsRegisteredOnceAndDoesNotOverrideLaterOptOut() throws {
        try withDefaults { defaults, _ in
            var registrations = 0
            try LaunchAtLoginPreferences.configureDefault(in: defaults, status: .notRegistered) { registrations += 1 }
            #expect(registrations == 1)
            #expect(defaults.bool(forKey: PreferenceKey.launchAtLoginConfigured.rawValue))
            try LaunchAtLoginPreferences.configureDefault(in: defaults, status: .notRegistered) { registrations += 1 }
            #expect(registrations == 1)
        }
        try withDefaults { defaults, _ in
            LaunchAtLoginPreferences.rememberUserChoice(in: defaults)
            var registrations = 0
            try LaunchAtLoginPreferences.configureDefault(in: defaults, status: .notRegistered) { registrations += 1 }
            #expect(registrations == 0)
        }
    }

    @MainActor
    @Test func existingLoginItemsAndPendingApprovalDoNotRegisterAgain() throws {
        for status in [SMAppService.Status.enabled, .requiresApproval] {
            try withDefaults { defaults, _ in
                var registrations = 0
                try LaunchAtLoginPreferences.configureDefault(in: defaults, status: status) { registrations += 1 }
                #expect(registrations == 0)
                #expect(defaults.bool(forKey: PreferenceKey.launchAtLoginConfigured.rawValue))
            }
        }
    }

    @MainActor
    @Test func unsuccessfulLoginRegistrationCanRetryOnNextLaunch() throws {
        enum RegistrationError: Error { case unavailable }
        try withDefaults { defaults, _ in
            #expect(throws: RegistrationError.self) {
                try LaunchAtLoginPreferences.configureDefault(in: defaults, status: .notRegistered) {
                    throw RegistrationError.unavailable
                }
            }
            #expect(!defaults.bool(forKey: PreferenceKey.launchAtLoginConfigured.rawValue))
            try LaunchAtLoginPreferences.configureDefault(in: defaults, status: .notFound) {}
            #expect(!defaults.bool(forKey: PreferenceKey.launchAtLoginConfigured.rawValue))
        }
    }

    @MainActor
    @Test func diffFileExpansionDefaultsToCollapsedAndPersistsTheSelectedMode() {
        withDefaults { defaults, _ in
            let key = PreferenceKey.diffFileExpansion.rawValue
            let preference = AppStorage(wrappedValue: AppPreferences.defaultDiffFileExpansion, key, store: defaults)
            #expect(!preference.wrappedValue.isExpanded)
            preference.wrappedValue = .expanded
            #expect(defaults.string(forKey: key) == "expanded")
            let restored = AppStorage(wrappedValue: AppPreferences.defaultDiffFileExpansion, key, store: defaults)
            #expect(restored.wrappedValue.isExpanded)
            restored.wrappedValue = .collapsed
            #expect(!restored.wrappedValue.isExpanded)
            #expect(defaults.string(forKey: key) == "collapsed")
        }
    }

    @Test func fontSizeIsBoundedAndPreservesValidChoices() {
        withDefaults { defaults, _ in
            for (saved, expected) in [(8.0, 11.0), (16.0, 16.0), (26.0, 18.0), (.nan, 12.0)] {
                defaults.set(saved, forKey: PreferenceKey.codeFontSize.rawValue)
                #expect(AppPreferences.codeFontSize(in: defaults) == CGFloat(expected))
            }
        }
    }

    @Test func explicitLanguageAndAutomaticUseOnlyApplicationDefaults() {
        withDefaults { defaults, name in
            InterfaceLanguage.simplifiedChinese.apply(to: defaults)
            #expect(defaults.stringArray(forKey: "AppleLanguages") == ["zh-Hans"])
            InterfaceLanguage.english.apply(to: defaults)
            #expect(defaults.stringArray(forKey: "AppleLanguages") == ["en"])
            InterfaceLanguage.automatic.apply(to: defaults)
            #expect(defaults.persistentDomain(forName: name)?["AppleLanguages"] == nil)
        }
    }

    @Test func supportedLanguagesMatchBundledTranslations() {
        let expected: Set<String> = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "es", "ru"]
        #expect(Set(InterfaceLanguage.allCases.filter { $0 != .automatic }.map(\.rawValue)) == expected)
    }

    @Test func repositoryDisplayNameDefaultsToFolderAndDoesNotChangeRepositoryIdentity() {
        let repository = WorkspaceEntry(url: URL(fileURLWithPath: "/projects/FoldGit"))
        let original = repository
        var names = RepositoryDisplayNames.decode(PreferenceDefaults.repositoryDisplayNames)
        #expect(names.displayName(for: repository) == "FoldGit")
        #expect(names.customName(for: repository) == nil)

        names.setName("  FoldGit 客户端 \n", for: repository)
        #expect(names.displayName(for: repository) == "FoldGit 客户端")
        #expect(repository == original)
        #expect(repository.url.lastPathComponent == "FoldGit")
    }

    @Test func repositoryDisplayNamesPersistByPathAcrossRediscovery() throws {
        try withDefaults { defaults, _ in
            let first = WorkspaceEntry(url: URL(fileURLWithPath: "/projects/work/client"))
            let second = WorkspaceEntry(url: URL(fileURLWithPath: "/projects/personal/client"))
            var names = RepositoryDisplayNames()
            names.setName("工作项目", for: first)
            names.setName("个人项目", for: second)
            defaults.set(try JSONEncoder().encode(names), forKey: PreferenceKey.repositoryDisplayNames.rawValue)

            let data = try #require(defaults.data(forKey: PreferenceKey.repositoryDisplayNames.rawValue))
            let restored = RepositoryDisplayNames.decode(data)
            let rediscovered = WorkspaceEntry(url: first.url.appendingPathComponent("."))
            #expect(restored.displayName(for: rediscovered) == "工作项目")
            #expect(restored.displayName(for: second) == "个人项目")
            #expect(restored == names)
        }
    }

    @Test func repositoryDisplayNameCanBeRenamedAndResetWithoutAffectingOtherRepositories() {
        let repository = WorkspaceEntry(url: URL(fileURLWithPath: "/projects/FoldGit"))
        let other = WorkspaceEntry(url: URL(fileURLWithPath: "/projects/other"))
        var names = RepositoryDisplayNames()
        names.setName("其他项目", for: other)
        for reset in ["", " \n\t", "FoldGit"] {
            names.setName("原名称", for: repository)
            names.setName("新名称", for: repository)
            #expect(names.displayName(for: repository) == "新名称")
            names.setName(reset, for: repository)
            #expect(names.customName(for: repository) == nil)
            #expect(names.displayName(for: repository) == "FoldGit")
            #expect(names.displayName(for: other) == "其他项目")
        }
    }

    @Test func commitPrefixPreservesDescriptionBodyScopeAndBreakingMarker() {
        let body = "修复登录失败\n\n保留详细说明\n\nRefs: #123"
        #expect(CommitMessageSnippet.applying("fix: ", to: body) == "fix: " + body)
        #expect(CommitMessageSnippet.applying("fix: ", to: "feat(auth)!: " + body) == "fix(auth)!: " + body)
        #expect(CommitMessageSnippet.applying("docs: ", to: "fix: " + body) == "docs: " + body)
        #expect(CommitMessageSnippet.applying("fix: ", to: "fix: " + body) == "fix: " + body)
        #expect(CommitMessageSnippet.applying("fix: ", to: "") == "fix: ")
    }

    @Test func customSnippetsKeepTheirOriginalReplacementBehavior() {
        #expect(CommitMessageSnippet.applying("[fix] ", to: "原来的内容") == "[fix] ")
        #expect(CommitMessageSnippet.applying("自定义完整提交信息", to: "fix: 原来的内容") == "自定义完整提交信息")
    }

    @Test func legacyDefaultSnippetsMigrateAcrossInterfaceLanguages() throws {
        try withDefaults { defaults, _ in
            let key = PreferenceKey.commitMessageSnippet.rawValue
            let original = ["Tweaks", "Remove unused code", "Fix lint warnings"]
            for language in Bundle.main.localizations {
                let url = try #require(Bundle.main.url(forResource: language, withExtension: "lproj"))
                let bundle = try #require(Bundle(url: url))
                let previous = original.map { bundle.localizedString(forKey: $0, value: nil, table: nil) }
                defaults.set(try JSONEncoder().encode(previous), forKey: key)
                PreferenceDefaults.migrateLegacyCommitMessageSnippets(in: defaults)
                #expect(defaults.object(forKey: key) == nil)
            }
        }
    }

    @Test func snippetMigrationPreservesCustomListsEmptyListsAndUnreadableData() throws {
        try withDefaults { defaults, _ in
            let key = PreferenceKey.commitMessageSnippet.rawValue
            for snippets in [["[fix] ", "[feat] "], ["Tweaks", "自定义短语"], [], CommitMessageSnippet.defaultPrefixes] {
                let saved = try JSONEncoder().encode(snippets)
                defaults.set(saved, forKey: key)
                PreferenceDefaults.migrateLegacyCommitMessageSnippets(in: defaults)
                #expect(defaults.data(forKey: key) == saved)
            }
            let unreadable = Data("invalid JSON".utf8)
            defaults.set(unreadable, forKey: key)
            PreferenceDefaults.migrateLegacyCommitMessageSnippets(in: defaults)
            #expect(defaults.data(forKey: key) == unreadable)
        }
    }

    @Test func defaultQuickInputShowsOnlyThreePrefixes() {
        let entries = CommitMessageSnippetEntry.decode(PreferenceDefaults.commitMessageSnippetEntries)
        #expect(entries.map(\.text) == CommitMessageSnippet.defaultPrefixes)
        #expect(entries.filter(\.isFavorite).map(\.text) == ["fix: ", "feat: ", "docs: "])
    }

    @Test func snippetEntriesMigrateCustomTextDuplicatesAndEmptyLists() throws {
        try withDefaults { defaults, _ in
            let oldKey = PreferenceKey.commitMessageSnippet.rawValue
            let newKey = PreferenceKey.commitMessageSnippetEntries.rawValue
            for snippets in [["[fix] ", "[fix] ", "自定义短语\n第二行", "build: "], []] {
                defaults.removeObject(forKey: newKey)
                let original = try JSONEncoder().encode(snippets)
                defaults.set(original, forKey: oldKey)
                PreferenceDefaults.migrateCommitMessageSnippetEntries(in: defaults)
                let saved = try #require(defaults.data(forKey: newKey))
                let entries = try JSONDecoder().decode([CommitMessageSnippetEntry].self, from: saved)
                #expect(entries.map(\.text) == snippets)
                #expect(entries.filter(\.isFavorite).map(\.text) == Array(snippets.prefix(3)))
                #expect(Set(entries.map(\.id)).count == entries.count)
                #expect(defaults.data(forKey: oldKey) == original)
            }
        }
    }

    @Test func snippetMigrationKeepsSavedEditsFavoritesAndDeletedEntries() throws {
        try withDefaults { defaults, _ in
            let newKey = PreferenceKey.commitMessageSnippetEntries.rawValue
            let entry = CommitMessageSnippetEntry(text: "自定义快捷输入 ", isFavorite: false)
            let saved = try JSONEncoder().encode([entry])
            defaults.set(saved, forKey: newKey)
            defaults.set(PreferenceDefaults.commitMessageSnippets, forKey: PreferenceKey.commitMessageSnippet.rawValue)
            PreferenceDefaults.migrateCommitMessageSnippetEntries(in: defaults)
            #expect(defaults.data(forKey: newKey) == saved)
            #expect(CommitMessageSnippetEntry.decode(saved) == [entry])

            let empty = try JSONEncoder().encode([CommitMessageSnippetEntry]())
            defaults.set(empty, forKey: newKey)
            PreferenceDefaults.migrateCommitMessageSnippetEntries(in: defaults)
            #expect(defaults.data(forKey: newKey) == empty)
        }
    }

    @Test func snippetEntryMigrationLeavesUnreadableLegacyDataUntouched() {
        withDefaults { defaults, _ in
            let invalid = Data("invalid JSON".utf8)
            defaults.set(invalid, forKey: PreferenceKey.commitMessageSnippet.rawValue)
            PreferenceDefaults.migrateCommitMessageSnippetEntries(in: defaults)
            #expect(defaults.data(forKey: PreferenceKey.commitMessageSnippet.rawValue) == invalid)
            #expect(defaults.object(forKey: PreferenceKey.commitMessageSnippetEntries.rawValue) == nil)
        }
    }
}
