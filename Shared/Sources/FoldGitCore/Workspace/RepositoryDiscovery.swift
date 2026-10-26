import Foundation

/// Only roots of working repositories are selectable. Ordinary working-tree subdirectories
/// inherit Git metadata from their parent and must never become separate repositories.
public actor RepositoryDiscovery {
    private let acceptsDirectory: @Sendable (URL) -> Bool

    public init(acceptsDirectory: @escaping @Sendable (URL) -> Bool = { _ in true }) {
        self.acceptsDirectory = acceptsDirectory
    }

    public enum DiscoveryError: LocalizedError, Sendable {
        case noRepositories

        public var errorDescription: String? {
            NSLocalizedString("Choose a Git repository or a folder containing repositories in its immediate subfolders.", comment: "")
        }
    }

    public func inspect(_ directory: URL) async throws -> WorkspaceEntry {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        if await isRepositoryRoot(directory) { return WorkspaceEntry(url: directory) }
        let group = try await scanGroup(directory)
        guard group.children?.isEmpty == false else { throw DiscoveryError.noRepositories }
        return group
    }

    public func scanGroup(_ directory: URL) async throws -> WorkspaceEntry {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        )
        var repositories: [WorkspaceEntry] = []
        for entry in entries {
            try Task.checkCancellation()
            let values = try entry.resourceValues(forKeys: keys)
            guard values.isDirectory == true, values.isSymbolicLink != true, acceptsDirectory(entry) else { continue }
            if await isRepositoryRoot(entry) {
                repositories.append(WorkspaceEntry(url: entry.standardizedFileURL.resolvingSymlinksInPath()))
            }
        }
        repositories.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return WorkspaceEntry(url: directory, children: repositories)
    }

    private func isRepositoryRoot(_ directory: URL) async -> Bool {
        // .git may be a directory or a file, as used by worktrees and submodules.
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path),
              let output = try? await GitRuntime.run(
                arguments: ["git", "rev-parse", "--show-toplevel"], currentDirectoryURL: directory, readOnly: true
              ) else { return false }
        let root = URL(fileURLWithPath: output.standardOutput.trimmingCharacters(in: .newlines))
        return root.standardizedFileURL.resolvingSymlinksInPath() == directory.standardizedFileURL.resolvingSymlinksInPath()
    }
}
