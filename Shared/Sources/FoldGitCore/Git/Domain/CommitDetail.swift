import Foundation

public struct CommitDetail: Hashable, Sendable {
    public init(commit: Commit, diff: Diff) {
        self.commit = commit
        self.diff = diff
    }

    public var commit: Commit
    public var diff: Diff
}
