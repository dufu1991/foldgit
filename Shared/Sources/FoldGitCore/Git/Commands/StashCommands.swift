import Foundation

public struct GitStash: GitAction {
    public var directory: URL
    public var message = ""
    public init(directory: URL, message: String = "") { self.directory = directory; self.message = message }
    public var arguments: [String] { ["git", "stash", "--include-untracked"] + (message.isEmpty ? [] : ["-m", message]) }
}

public struct GitStashApply: GitAction {
    public var directory: URL
    public var index: Int
    public init(directory: URL, index: Int) { self.directory = directory; self.index = index }
    public var arguments: [String] { ["git", "stash", "apply", "\(index)"] }
}

public struct GitStashDrop: GitAction {
    public var directory: URL
    public var index: Int
    public init(directory: URL, index: Int) { self.directory = directory; self.index = index }
    public var arguments: [String] { ["git", "stash", "drop", "\(index)"] }
}

public struct GitStashList: RepositoryCommand {
    public var directory: URL
    public init(directory: URL) { self.directory = directory }

    public var isReadOnly: Bool { true }
    public var arguments: [String] { ["git", "stash", "list"] }

    public func parse(for stdOut: String) throws -> [Stash] {
        stdOut.components(separatedBy: .newlines).filter { !$0.isEmpty }.enumerated().map { Stash(index: $0, raw: $1) }
    }
}

public struct GitStashShowDiff: GitTextQuery {
    public var directory: URL
    public var index: Int
    public init(directory: URL, index: Int) { self.directory = directory; self.index = index }
    public var arguments: [String] { ["git", "stash", "show", "--include-untracked", "--full-index", "-p", "\(index)"] }
}

/// Applies a stash and removes it when it applied cleanly; Git keeps the entry if the apply conflicts.
public struct GitStashPop: GitAction {
    public var directory: URL
    public var index: Int
    public init(directory: URL, index: Int) { self.directory = directory; self.index = index }
    public var arguments: [String] { ["git", "stash", "pop", "\(index)"] }
}

/// A stash entry with the branch it was created on and its creation time.
public struct StashListEntry: Identifiable, Hashable, Sendable {
    public var id: Int { index }
    public var index: Int
    public var message: String
    public var branch: String?
    public var date: Date?

    public init(index: Int, message: String, branch: String?, date: Date?) {
        self.index = index
        self.message = message
        self.branch = branch
        self.date = date
    }

    /// Parses a reflog subject such as `WIP on main: abc1234 Title` or `On main: message`.
    public init(index: Int, subject: String, timestamp: String) {
        var branch: String?
        var message = subject
        for prefix in ["WIP on ", "On "] where subject.hasPrefix(prefix) {
            let rest = subject.dropFirst(prefix.count)
            if let colon = rest.range(of: ": ") {
                branch = String(rest[..<colon.lowerBound])
                message = String(rest[colon.upperBound...])
            }
            break
        }
        self.init(index: index, message: message, branch: branch,
                  date: TimeInterval(timestamp.trimmingCharacters(in: .whitespaces)).map { Date(timeIntervalSince1970: $0) })
    }
}

/// `git stash list` with machine-readable fields: selector, reflog subject and committer timestamp.
public struct GitStashListDetails: RepositoryCommand {
    public var directory: URL
    public init(directory: URL) { self.directory = directory }

    public var isReadOnly: Bool { true }
    public var arguments: [String] { ["git", "stash", "list", "--format=%gd%x1f%gs%x1f%ct"] }

    public func parse(for stdOut: String) throws -> [StashListEntry] {
        stdOut.components(separatedBy: .newlines).filter { !$0.isEmpty }.enumerated().map { offset, line in
            let fields = line.components(separatedBy: "\u{1f}")
            let selector = fields[0]
            let index = selector.firstRange(of: "{").flatMap { open in
                selector[open.upperBound...].split(separator: "}").first.flatMap { Int($0) }
            } ?? offset
            return StashListEntry(index: index, subject: fields.count > 1 ? fields[1] : "",
                                  timestamp: fields.count > 2 ? fields[2] : "")
        }
    }
}
