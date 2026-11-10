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
            try requireLosslessPatch(selection.patch)
            try await GitRuntime.run(GitApplyCached(directory: directory, patch: selection.patch, reverse: !staging))
        }
        if !selection.paths.isEmpty {
            try await GitRuntime.run(GitIndexPaths(directory: directory, paths: selection.paths, staging: staging))
        }
    }
}

/// Diff text from a file that is not UTF-8 was decoded lossily; applying it would write U+FFFD into the file.
func requireLosslessPatch(_ patch: String) throws {
    guard !patch.contains("\u{FFFD}") else {
        throw GitExecutionError(description: NSLocalizedString(
            "This file is not UTF-8 text. Stage or discard it as a complete file.", comment: ""))
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

/// Restores tracked files in the working tree from the index, discarding their unstaged changes.
public struct GitRestoreWorktree: GitAction {
    public var directory: URL
    public let paths: [String]
    public init(directory: URL, paths: [String]) { self.directory = directory; self.paths = paths }
    public var arguments: [String] { ["git", "--literal-pathspecs", "restore", "--worktree", "--"] + paths }
}

/// Reverse-applies selected hunks of the unstaged diff to the working tree only.
struct GitApplyWorktreeReverse: InteractiveRepositoryCommand, GitAction {
    var directory: URL
    let patch: String
    var arguments: [String] { ["git", "apply", "--whitespace=nowarn", "--reverse"] }
    var inputs: [String] { [patch] }
}

/// Discards unstaged changes. Untracked files are never deleted by Git here: callers move them to the Trash instead.
public enum WorktreeDiscarding {
    /// `selection` uses the staging shape: the files and hunks to discard are the ones marked as staged.
    /// A stale patch fails instead of discarding a different hunk.
    public static func discard(_ selection: IndexSelection, in directory: URL) async throws {
        if !selection.patch.isEmpty {
            try requireLosslessPatch(selection.patch)
            try await GitRuntime.run(GitApplyWorktreeReverse(directory: directory, patch: selection.patch))
        }
        if !selection.paths.isEmpty {
            try await GitRuntime.run(GitRestoreWorktree(directory: directory, paths: selection.paths))
        }
    }

    /// The files a discard would touch, resolved inside `directory`. Paths that leave the repository are rejected.
    public static func untrackedFileURLs(_ paths: [String], in directory: URL) throws -> [URL] {
        let root = directory.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return try paths.map { path in
            let url = directory.appendingPathComponent(path).standardizedFileURL
            guard !path.isEmpty, url.path.hasPrefix(prefix), !path.split(separator: "/").contains("..") else {
                throw GenericError(errorDescription: "Refusing to remove a path outside the repository: \(path)")
            }
            return url
        }
    }

    #if os(macOS)
    /// Moves untracked files to the Trash so they can be recovered, instead of `git clean`.
    public static func trashUntrackedFiles(_ paths: [String], in directory: URL,
                                           fileManager: FileManager = .default) throws {
        for url in try untrackedFileURLs(paths, in: directory) where fileManager.fileExists(atPath: url.path) {
            try fileManager.trashItem(at: url, resultingItemURL: nil)
        }
    }
    #endif
}

/// The full message of `HEAD`, used to prefill an amend.
public struct GitHeadMessage: GitTextQuery {
    public var directory: URL
    public init(directory: URL) { self.directory = directory }
    public var arguments: [String] { ["git", "log", "-1", "--format=%B", "HEAD"] }
}
