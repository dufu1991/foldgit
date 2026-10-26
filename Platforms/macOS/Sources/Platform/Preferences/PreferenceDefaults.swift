import FoldGitCore
import Foundation

struct PreferenceDefaults {
    static let showWorktreeInformation = true
    static let repositoryWorktreeVisibility = try! JSONEncoder().encode(RepositoryWorktreePreferences())
    static let repositoryDisplayNames = try! JSONEncoder().encode(RepositoryDisplayNames())
    static let sidebarDates = try! JSONEncoder().encode(SidebarDates())
    static let commitMessageSnippets = try! JSONEncoder().encode(CommitMessageSnippet.defaultPrefixes)
    static let commitMessageSnippetEntries = try! JSONEncoder().encode(CommitMessageSnippetEntry.defaults)

    static func migrateWorkspaceGroups(in defaults: UserDefaults = .standard) {
        let key = PreferenceKey.folder.rawValue
        guard let original = defaults.data(forKey: key),
              let folders = try? JSONDecoder().decode([WorkspaceEntry].self, from: original),
              folders.contains(where: { !$0.isRepository && !$0.isLogicalGroup }),
              let migrated = try? JSONEncoder().encode(WorkspaceGroups.migratingDirectoryGroups(folders)) else { return }
        let backup = PreferenceKey.folderBeforeLogicalGroups.rawValue
        if defaults.data(forKey: backup) == nil { defaults.set(original, forKey: backup) }
        defaults.set(migrated, forKey: key)
    }

    static func migrateCommitMessageSnippetEntries(in defaults: UserDefaults = .standard) {
        let key = PreferenceKey.commitMessageSnippetEntries.rawValue
        guard defaults.object(forKey: key) == nil,
              let data = defaults.data(forKey: PreferenceKey.commitMessageSnippet.rawValue),
              let snippets = try? JSONDecoder().decode([String].self, from: data) else { return }
        let entries = CommitMessageSnippetEntry.migrating(snippets)
        defaults.set(try! JSONEncoder().encode(entries), forKey: key)
    }

    static func migrateLegacyCommitMessageSnippets(in defaults: UserDefaults = .standard) {
        let key = PreferenceKey.commitMessageSnippet.rawValue
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode([String].self, from: data) else { return }

        let original = ["Tweaks", "Remove unused code", "Fix lint warnings"]
        let localized = [
            String(localized: "Tweaks"),
            String(localized: "Remove unused code"),
            String(localized: "Fix lint warnings"),
        ]
        let translations = Bundle.main.localizations.compactMap { language -> [String]? in
            guard let url = Bundle.main.url(forResource: language, withExtension: "lproj"),
                  let bundle = Bundle(url: url) else { return nil }
            return original.map { bundle.localizedString(forKey: $0, value: nil, table: nil) }
        }
        if ([original, localized] + translations).contains(saved) {
            defaults.removeObject(forKey: key)
        }
    }
}

/// The saved repository choices survive turning the global feature off and on.
struct RepositoryWorktreePreferences: Codable, Equatable {
    private var overrides: [String: Bool] = [:]

    func isEnabled(for repository: URL, global: Bool) -> Bool {
        global && overrides[RepositoryLocation.key(for: repository)] == true
    }

    mutating func setEnabled(_ enabled: Bool, for repository: URL) {
        let key = RepositoryLocation.key(for: repository)
        if enabled { overrides[key] = true }
        else { overrides.removeValue(forKey: key) }
    }

    static func decode(_ data: Data) -> Self {
        (try? JSONDecoder().decode(Self.self, from: data)) ?? Self()
    }
}

struct RepositoryDisplayNames: Codable, Equatable {
    private var names: [String: String] = [:]

    func customName(for repository: WorkspaceEntry) -> String? {
        names[repository.identity.path]
    }

    func displayName(for repository: WorkspaceEntry) -> String {
        customName(for: repository) ?? repository.url.lastPathComponent
    }

    mutating func setName(_ name: String, for repository: WorkspaceEntry) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = repository.identity.path
        if name.isEmpty || name == repository.url.lastPathComponent {
            names.removeValue(forKey: key)
        } else {
            names[key] = name
        }
    }

    static func decode(_ data: Data) -> Self {
        (try? JSONDecoder().decode(Self.self, from: data)) ?? Self()
    }
}

struct CommitMessageSnippetEntry: Codable, Equatable, Identifiable {
    var id = UUID()
    var text: String
    var isFavorite: Bool

    static let defaults = migrating(CommitMessageSnippet.defaultPrefixes)

    static func migrating(_ snippets: [String]) -> [Self] {
        snippets.enumerated().map { index, text in
            Self(text: text, isFavorite: index < 3)
        }
    }

    static func decode(_ data: Data) -> [Self] {
        (try? JSONDecoder().decode([Self].self, from: data)) ?? []
    }
}

enum CommitMessageSnippet {
    static let defaultPrefixes = [
        "fix: ", "feat: ", "docs: ", "refactor: ", "perf: ", "test: ",
        "style: ", "build: ", "ci: ", "chore: ", "revert: ",
    ]

    static func applying(_ snippet: String, to message: String) -> String {
        guard defaultPrefixes.contains(snippet) else { return snippet }
        guard !message.isEmpty else { return snippet }
        let typeRange = message.range(
            of: #"^[A-Za-z][A-Za-z0-9-]*(?=(\([^\r\n)]+\))?!?:[ \t])"#,
            options: .regularExpression
        )
        if let typeRange {
            return message.replacingCharacters(in: typeRange, with: String(snippet.dropLast(2)))
        }
        return snippet + message
    }
}

/// Stored JSON is decoded once per change instead of on every view update.
@MainActor
final class DecodedPreference<Value> {
    private let decode: (Data?) -> Value
    private var data: Data?
    private var value: Value?

    init(decode: @escaping (Data?) -> Value) { self.decode = decode }

    func value(for data: Data?) -> Value {
        if let value, data == self.data { return value }
        let decoded = decode(data)
        self.data = data
        value = decoded
        return decoded
    }
}
