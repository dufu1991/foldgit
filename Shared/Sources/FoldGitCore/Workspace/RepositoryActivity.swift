import Foundation

/// Reads tracked and nonignored worktree files away from the UI thread.
public actor RepositoryActivity {
    private var cache: [URL: (scanned: Date, modified: Date?)] = [:]

    public init() {}

    /// Forces the next request to scan, for example after a file system event in the repository.
    public func invalidate(_ directory: URL) {
        cache[RepositoryLocation.canonical(directory)] = nil
    }

    public func modificationDate(at directory: URL) async throws -> Date? {
        let directory = RepositoryLocation.canonical(directory)
        if let cached = cache[directory], Date.now.timeIntervalSince(cached.scanned) < 20 {
            return cached.modified
        }
        let output = try await GitRuntime.run(
            arguments: ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            currentDirectoryURL: directory, readOnly: true
        )
        var latest: Date?
        for (offset, path) in output.standardOutput.split(separator: "\0").enumerated() {
            if offset.isMultiple(of: 256) { try Task.checkCancellation() }
            let file = directory.appendingPathComponent(String(path))
            // One stat per file; a missing tracked file uses its parent directory's removal time.
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? (try? file.deletingLastPathComponent().resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            if let date { latest = max(latest ?? date, date) }
        }
        cache[directory] = (.now, latest)
        return latest
    }
}
