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
