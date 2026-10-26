import Foundation

public struct GitAdd: GitAction {
    public var directory: URL
    public init(directory: URL) { self.directory = directory }
    public var arguments: [String] { ["git", "add", "."] }
}

public struct GitAddPathspec: GitAction {
    public var directory: URL
    public var pathspec: String
    public init(directory: URL, pathspec: String) { self.directory = directory; self.pathspec = pathspec }
    public var arguments: [String] { ["git", "add", "--", pathspec] }
}

public struct GitRestore: GitAction {
    public var directory: URL
    public init(directory: URL) { self.directory = directory }
    public var arguments: [String] { ["git", "restore", "--staged", "."] }
}

/// Applies a selection to the index. A stale patch fails instead of staging a different hunk.
public enum IndexStaging {
    public static func apply(_ selection: IndexSelection, staging: Bool, in directory: URL) async throws {
        if !selection.patch.isEmpty {
            try await GitRuntime.run(GitApplyCached(directory: directory, patch: selection.patch, reverse: !staging))
        }
        if !selection.paths.isEmpty {
            try await GitRuntime.run(GitIndexPaths(directory: directory, paths: selection.paths, staging: staging))
        }
    }
}

struct GitApplyCached: InteractiveRepositoryCommand, GitAction {
    var directory: URL
    let patch: String
    let reverse: Bool
    var arguments: [String] { ["git", "apply", "--cached", "--whitespace=nowarn"] + (reverse ? ["--reverse"] : []) }
    var inputs: [String] { [patch] }
}

struct GitIndexPaths: GitAction {
    var directory: URL
    let paths: [String]
    let staging: Bool
    var arguments: [String] {
        ["git", "--literal-pathspecs"] + (staging ? ["add"] : ["restore", "--staged"]) + ["--"] + paths
    }
}

public struct GitCommit: GitAction {
    public var directory: URL
    public var message: String
    public var amend = false
    public init(directory: URL, message: String, amend: Bool = false) {
        self.directory = directory
        self.message = message
        self.amend = amend
    }
    public var arguments: [String] { ["git", "commit"] + (amend ? ["--amend"] : []) + ["-m", message] }
}

public struct GitStatus: RepositoryCommand {
    public var directory: URL
    public init(directory: URL) { self.directory = directory }

    public var isReadOnly: Bool { true }
    public var arguments: [String] { ["git", "status", "--porcelain=v2", "-z", "--untracked-files=all"] }

    public func parse(for output: String) throws -> Status {
        let records = output.components(separatedBy: "\0")
        var untracked: [String] = []
        var conflicts: [String] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            if record.hasPrefix("? ") {
                untracked.append(String(record.dropFirst(2)))
            } else if record.hasPrefix("u ") {
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11 else { throw GitExecutionError(description: "Invalid unmerged status from Git.") }
                conflicts.append(String(fields[10]))
            } else if record.hasPrefix("2 ") {
                // A rename has a second NUL-delimited pathname, which is not a status record.
                index += 1
            }
            index += 1
        }
        return Status(untrackedFiles: untracked, unmergedFiles: conflicts)
    }
}
