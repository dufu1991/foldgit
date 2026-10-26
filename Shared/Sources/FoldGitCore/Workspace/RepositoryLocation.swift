import Foundation

public enum RepositoryLocation: Sendable {
    public static func key(for directory: URL) -> String {
        canonical(directory).path
    }

    /// Symlink resolution reads every path component, and views compare identities on each update.
    /// Only existing paths are cached, so a later folder at a missing path still resolves correctly.
    public static func canonical(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        if let cached = cache.value(for: standardized.path) { return cached }
        let resolved = standardized.resolvingSymlinksInPath()
        if FileManager.default.fileExists(atPath: resolved.path) { cache.store(resolved, for: standardized.path) }
        return resolved
    }

    private static let cache = CanonicalPathCache()
}

private final class CanonicalPathCache: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String: URL] = [:]

    func value(for path: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return paths[path]
    }

    func store(_ url: URL, for path: String) {
        lock.lock()
        defer { lock.unlock() }
        if paths.count >= 4_096 { paths.removeAll(keepingCapacity: true) }
        paths[path] = url
    }
}
