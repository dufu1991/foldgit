import Foundation

public struct WorktreeSnapshot: Sendable {
    public init(unstaged: String, staged: String, status: Status) {
        self.unstaged = unstaged
        self.staged = staged
        self.status = status
    }

    public let unstaged: String
    public let staged: String
    public let status: Status

    public var changes: NotCommitted { NotCommitted(diff: unstaged, diffCached: staged, status: status) }

    /// The reads share one queue slot, so no write from the app lands between them.
    public static func read(in directory: URL) async throws -> WorktreeSnapshot {
        try await GitRuntime.read(at: directory, readOnly: true) { session in
            async let status = session.run(GitStatus(directory: directory))
            async let staged = session.run(GitDiff(directory: directory, cached: true))
            async let unstaged = session.run(GitDiff(directory: directory))
            return try await WorktreeSnapshot(unstaged: unstaged, staged: staged, status: status)
        }
    }
}
