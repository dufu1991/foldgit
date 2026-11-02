import Foundation

/// Paths only: opening the browser never reads the contents of repository files.
public struct GitRepositoryFiles: RepositoryCommand {
    public var directory: URL
    public init(directory: URL) { self.directory = directory }
    public var isReadOnly: Bool { true }
    public var arguments: [String] {
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--deduplicate"]
    }
    public func parse(for output: String) -> [String] {
        Array(Set(output.split(separator: "\0").map(String.init))).sorted()
    }
}

public struct FileHistoryEntry: Identifiable, Hashable, Sendable {
    public let commit: Commit
    public let oldPath: String?
    public let newPath: String?
    public var id: String { commit.id }
}

/// Read a bounded prefix from a pinned tip. --skip can discard rename transitions before --follow sees them.
public struct GitFileHistory: RepositoryCommand {
    public var directory: URL
    public let path: String
    public let revision: String
    public let limit: Int

    public init(directory: URL, path: String, revision: String, limit: Int = 51) {
        precondition(limit > 0)
        self.directory = directory
        self.path = path
        self.revision = revision
        self.limit = limit
    }

    public var isReadOnly: Bool { true }
    public var arguments: [String] {
        ["git", "--literal-pathspecs", "log", "--follow", "--find-renames", "--diff-merges=first-parent",
         "--name-status", "-z", "--format=\(CommitRecord.format.replacingOccurrences(of: "%D", with: ""))", "--max-count=\(limit)",
         revision, "--", path]
    }

    public func parse(for output: String) throws -> [FileHistoryEntry] {
        guard !output.isEmpty else { return [] }
        let fields = output.components(separatedBy: "\0")
        var offset = 0
        var entries: [FileHistoryEntry] = []
        while offset < fields.count {
            while offset < fields.count && fields[offset].trimmingCharacters(in: .newlines).isEmpty { offset += 1 }
            guard offset < fields.count else { break }
            guard offset + 8 <= fields.count else { throw invalidRecords() }
            let commit = try CommitRecord.decode(Array(fields[offset..<(offset + 8)]))
            offset += 8
            // -z terminates the pretty record separately from the name/status record.
            if offset < fields.count && fields[offset].isEmpty { offset += 1 }
            guard offset < fields.count else { throw invalidRecords() }
            let status = fields[offset].trimmingCharacters(in: .newlines)
            offset += 1
            guard let kind = status.first, "AMDTRC".contains(kind), offset < fields.count,
                  !fields[offset].isEmpty else { throw invalidRecords() }
            let first = fields[offset]
            offset += 1
            let oldPath: String?
            let newPath: String?
            if kind == "R" || kind == "C" {
                guard offset < fields.count, !fields[offset].isEmpty else { throw invalidRecords() }
                oldPath = first
                newPath = fields[offset]
                offset += 1
            } else {
                oldPath = kind == "A" ? nil : first
                newPath = kind == "D" ? nil : first
            }
            entries.append(FileHistoryEntry(commit: commit, oldPath: oldPath, newPath: newPath))
        }
        return entries
    }

    private func invalidRecords() -> GitExecutionError {
        GitExecutionError(description: NSLocalizedString("Invalid file history records from Git.", comment: ""))
    }
}

/// Restrict the patch at the source; never load a repository-wide patch just to filter it in the UI.
public struct GitFileHistoryDiff: RepositoryCommand {
    public var directory: URL
    public let entry: FileHistoryEntry
    public init(directory: URL, entry: FileHistoryEntry) { self.directory = directory; self.entry = entry }
    public var isReadOnly: Bool { true }
    public var arguments: [String] {
        let paths = Array(Set([entry.oldPath, entry.newPath].compactMap { $0 })).sorted()
        let options = ["--full-index", "--no-ext-diff", "--no-textconv", "--find-renames", "--src-prefix=a/", "--dst-prefix=b/"]
        if let parent = entry.commit.parentHashes.first {
            return ["git", "--literal-pathspecs", "diff"] + options + [parent, entry.commit.hash, "--"] + paths
        }
        return ["git", "--literal-pathspecs", "diff-tree", "--root", "--no-commit-id", "-p"]
            + options + [entry.commit.hash, "--"] + paths
    }
    public func parse(for output: String) throws -> Diff {
        var patch = try Diff(raw: output)
        patch.fileDiffs = patch.fileDiffs.filter { file in
            entry.oldPath.map { file.fromFilePath == $0 } != false
                && entry.newPath.map { file.toFilePath == $0 } != false
        }
        patch.raw = patch.fileDiffs.map(\.raw).joined(separator: "\n")
        return patch
    }
}
