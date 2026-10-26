import Foundation

enum LegacyPreferencesMigration {
    static func migrate(into defaults: UserDefaults = .standard, legacyDomain: String = "dev.aoyama.changes",
                        destinationDomain: String = "com.dufu.foldgit") {
        let marker = "foldgit.preferences.imported.v1"
        guard !defaults.bool(forKey: marker) else { return }
        let legacy = defaults.persistentDomain(forName: legacyDomain) ?? [:]
        let existing = defaults.persistentDomain(forName: destinationDomain) ?? [:]
        for key in PreferenceKey.allCases.map(\.rawValue) + ["AppleLanguages"] {
            if existing[key] == nil, let value = legacy[key] { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: marker)
    }
}
