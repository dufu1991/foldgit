import Foundation
import Testing
@testable import FoldGit

struct LegacyPreferencesMigrationTests {
    @Test func importsLegacyValuesOnceWithoutOverwritingNewPreferences() throws {
        let domain = "FoldGit.migration.\(UUID().uuidString)"
        let legacy = "FoldGit.legacy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain); defaults.removePersistentDomain(forName: legacy) }
        defaults.setPersistentDomain(["codeFontSize": 17.0, "restoreSession": false, "AppleLanguages": ["zh-Hans"]], forName: legacy)
        defaults.set(14.0, forKey: PreferenceKey.codeFontSize.rawValue)
        LegacyPreferencesMigration.migrate(into: defaults, legacyDomain: legacy, destinationDomain: domain)
        #expect(defaults.double(forKey: "codeFontSize") == 14)
        #expect(defaults.object(forKey: "restoreSession") as? Bool == false)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["zh-Hans"])
        defaults.set(true, forKey: "restoreSession")
        LegacyPreferencesMigration.migrate(into: defaults, legacyDomain: legacy, destinationDomain: domain)
        #expect(defaults.bool(forKey: "restoreSession"))
    }
}
