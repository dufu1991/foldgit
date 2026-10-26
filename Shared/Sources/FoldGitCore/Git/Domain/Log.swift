import Foundation

public enum Log: Identifiable, Hashable, Sendable {
    public var id: String {
        switch self {
        case .notCommitted:
            return "notCommitted"
        case .committed(let c):
            return c.hash
        }
    }

    case notCommitted, committed(Commit)
}

public struct NotCommitted: Hashable, Sendable {
    public init(diff: String, diffCached: String, status: Status) {
        self.diff = diff
        self.diffCached = diffCached
        self.status = status
    }

    public var diff: String
    public var diffCached: String
    public var status: Status
    public var isEmpty: Bool { (diff + diffCached).isEmpty && status.untrackedFiles.isEmpty }
}
