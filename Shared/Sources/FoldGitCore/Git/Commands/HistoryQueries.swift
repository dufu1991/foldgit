import Foundation

public struct GitLog: RepositoryCommand {
    public var directory: URL
    public var merges = false
    public var ancestryPath = false
    public var reverse = false
    public var number = 0
    public var skip = 0
    public var noWalk = false
    public var firstParent = false
    public var revisionRange: [String] = []

    public init(directory: URL, merges: Bool = false, ancestryPath: Bool = false, reverse: Bool = false,
                number: Int = 0, skip: Int = 0, noWalk: Bool = false, firstParent: Bool = false,
                revisionRange: [String] = []) {
        self.directory = directory
        self.merges = merges
        self.ancestryPath = ancestryPath
        self.reverse = reverse
        self.number = number
        self.skip = skip
        self.noWalk = noWalk
        self.firstParent = firstParent
        self.revisionRange = revisionRange
    }

    public var isReadOnly: Bool { true }
    public var arguments: [String] {
        var arguments = ["git", "log", "--pretty=format:\(CommitRecord.format)", "--topo-order"]
        if merges { arguments.append("--merges") }
        if ancestryPath { arguments.append("--ancestry-path") }
        if reverse { arguments.append("--reverse") }
        if number > 0 { arguments.append("-\(number)") }
        if skip > 0 { arguments.append("--skip=\(skip)") }
        if noWalk { arguments.append("--no-walk") }
        if firstParent { arguments.append("--first-parent") }
        return arguments + revisionRange
    }

    public func parse(for output: String) throws -> [Commit] {
        guard !output.isEmpty else { return [] }
        var fields = output.components(separatedBy: "\0")
        guard fields.removeLast().isEmpty, fields.count.isMultiple(of: CommitRecord.fieldCount) else {
            throw GitExecutionError(description: "Invalid commit records from Git.")
        }
        return try stride(from: 0, to: fields.count, by: CommitRecord.fieldCount).map { offset in
            try CommitRecord.decode(Array(fields[offset..<(offset + CommitRecord.fieldCount)]))
        }
    }
}

public struct GitShow: RepositoryCommand {
    public var directory: URL
    public var object: String
    public init(directory: URL, object: String) { self.directory = directory; self.object = object }

    public var isReadOnly: Bool { true }
    public var arguments: [String] { ["git", "show"] + GitPatchOptions.stable + ["--pretty=format:\(CommitRecord.format)", object] }

    public func parse(for output: String) throws -> CommitDetail {
        let fields = output.split(separator: "\0", maxSplits: CommitRecord.fieldCount, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == CommitRecord.fieldCount + 1 else { throw GitExecutionError(description: "Invalid commit detail from Git.") }
        return CommitDetail(commit: try CommitRecord.decode(Array(fields.prefix(CommitRecord.fieldCount))),
                            diff: try Diff(raw: fields[CommitRecord.fieldCount].trimmingCharacters(in: .newlines)))
    }
}

public struct GitShowShortstat: RepositoryCommand {
    public var directory: URL
    public var object: String
    public init(directory: URL, object: String) { self.directory = directory; self.object = object }

    public var isReadOnly: Bool { true }
    public var arguments: [String] { ["git", "show", "--shortstat", object] }

    public func parse(for stdOut: String) throws -> String {
        guard !stdOut.isEmpty else { throw GenericError(errorDescription: NSLocalizedString("Git returned no output.", comment: "")) }
        return String(stdOut.split(separator: "\n").last ?? "").trimmingCharacters(in: .whitespaces)
    }
}

public struct GitRevListCount: RepositoryCommand {
    public var directory: URL
    public var revisions: [String]
    public init(directory: URL, commit: String = "HEAD") { self.directory = directory; revisions = [commit] }
    public init(directory: URL, revisions: [String]) { self.directory = directory; self.revisions = revisions }

    public var isReadOnly: Bool { true }
    public var arguments: [String] { ["git", "rev-list", "--count"] + revisions + ["--"] }
    public func parse(for stdOut: String) -> Int? { Int(stdOut.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

public struct GitRevParse: RepositoryCommand {
    public var directory: URL
    public var gitPath: String
    public init(directory: URL, gitPath: String) { self.directory = directory; self.gitPath = gitPath }

    public var isReadOnly: Bool { true }
    public var arguments: [String] { ["git", "rev-parse"] + (gitPath.isEmpty ? [] : ["--git-path", gitPath]) }
    public func parse(for stdOut: String) -> String { stdOut.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The checked-out branch without listing every branch. Detached HEAD uses Git's display name.
public struct GitCurrentBranch: RepositoryCommand {
    public var directory: URL
    public init(directory: URL) { self.directory = directory }

    public var isReadOnly: Bool { true }
    public var arguments: [String] { ["git", "branch", "--show-current"] }

    public func parse(for stdOut: String) -> String? {
        let name = stdOut.trimmingCharacters(in: .newlines)
        return name.isEmpty ? nil : name
    }
}
