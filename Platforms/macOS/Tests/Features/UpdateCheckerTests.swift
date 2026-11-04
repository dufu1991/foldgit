import Foundation
import Testing
@testable import FoldGit

struct UpdateCheckerTests {
    @Test @MainActor func appRequiresAuthenticatedInAppUpdates() throws {
        let bundle = Bundle(for: UpdateChecker.self)
        let key = try #require(bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
        #expect(Data(base64Encoded: key)?.count == 32)
        let feed = try #require(bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String)
        #expect(URL(string: feed)?.scheme == "https")
        #expect(bundle.object(forInfoDictionaryKey: "SURequireSignedFeed") as? Bool == true)
        #expect(bundle.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool == true)
        #expect(bundle.object(forInfoDictionaryKey: "SUEnableInstallerLauncherService") == nil)
    }

    @Test @MainActor func launchPreferenceDefaultsToEnabledAndHonorsUserChoice() throws {
        let suite = "FoldGit-update-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(UpdateChecker.checksAtLaunch(in: defaults))
        defaults.set(false, forKey: PreferenceKey.checkForUpdatesAtLaunch.rawValue)
        #expect(!UpdateChecker.checksAtLaunch(in: defaults))
        defaults.set(true, forKey: PreferenceKey.checkForUpdatesAtLaunch.rawValue)
        #expect(UpdateChecker.checksAtLaunch(in: defaults))
    }

    @Test @MainActor func debugBuildCannotReplaceTheRunningApp() {
        UpdateChecker.shared.checkAtLaunch()
        UpdateChecker.shared.checkNow()
        #expect(!UpdateChecker.shared.canCheckForUpdates)
    }
}
