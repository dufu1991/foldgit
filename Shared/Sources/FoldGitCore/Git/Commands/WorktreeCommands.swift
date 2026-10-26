import Foundation

public struct GitWorktree: Hashable, Identifiable, Sendable {
    public let url: URL
    public let head: String?
    public let branch: String?
    public let isMain: Bool
    public let isBare: Bool
    public let isDetached: Bool
    public let lockReason: String?
    public let pruneReason: String?
    public var id: URL { RepositoryLocation.canonical(url) }
    public var isLocked: Bool { lockReason != nil }
    public var isPrunable: Bool { pruneReason != nil }

    public static func parse(_ output: String) throws -> [Self] {
        var records: [[String: String]] = []
        var record: [String: String] = [:]
        for field in output.components(separatedBy: "\0") {
            if field.isEmpty {
                if !record.isEmpty { records.append(record); record = [:] }
            } else {
                let parts = field.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                record[String(parts[0])] = parts.count == 2 ? String(parts[1]) : ""
            }
        }
        if !record.isEmpty { records.append(record) }
        return try records.enumerated().map { index, fields in
            guard let path = fields["worktree"], !path.isEmpty else {
                throw GitExecutionError(description: NSLocalizedString("Git returned invalid worktree information.", comment: ""))
            }
            let reference = fields["branch"]
            let branch = reference.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst(11)) : $0 }
            return Self(url: URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath(), head: fields["HEAD"], branch: branch,
                        isMain: index == 0 && fields["bare"] == nil, isBare: fields["bare"] != nil,
                        isDetached: fields["detached"] != nil, lockReason: fields["locked"], pruneReason: fields["prunable"])
        }
    }
}

public struct GitWorktreeList: RepositoryCommand {
    public var directory: URL
    public init(directory: URL) { self.directory = directory }
    public var isReadOnly: Bool { true }
    public var arguments: [String] { ["git", "worktree", "list", "--porcelain", "-z"] }
    public func parse(for standardOutput: String) throws -> [GitWorktree] { try GitWorktree.parse(standardOutput) }
}

public enum WorktreeBranch: Sendable {
    case existing(String)
    case new(name: String, startPoint: String)
    case detached(startPoint: String)
}

public enum WorktreeOperation: Sendable {
    case add(destination: URL, branch: WorktreeBranch)
    case remove(URL)
    case move(URL, destination: URL)
    case lock(URL)
    case unlock(URL)
    case prune
}

/// Git owns validation and refuses to remove dirty or locked worktrees. Never force these operations.
public struct GitWorktreeCommand: GitAction {
    public var directory: URL
    public let operation: WorktreeOperation
    public init(directory: URL, operation: WorktreeOperation) {
        self.directory = directory
        self.operation = operation
    }
    public var arguments: [String] {
        let prefix = ["git", "worktree"]
        return switch operation {
        case let .add(destination, branch):
            switch branch {
            case let .existing(name): prefix + ["add", "--", destination.path, name]
            case let .new(name, startPoint): prefix + ["add", "-b", name, "--", destination.path, startPoint]
            case let .detached(startPoint): prefix + ["add", "--detach", "--", destination.path, startPoint]
            }
        case let .remove(url): prefix + ["remove", "--", url.path]
        case let .move(url, destination): prefix + ["move", "--", url.path, destination.path]
        case let .lock(url): prefix + ["lock", "--", url.path]
        case let .unlock(url): prefix + ["unlock", "--", url.path]
        case .prune: prefix + ["prune", "--expire", "now"]
        }
    }
}
