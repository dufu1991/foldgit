import Foundation

/// A compact, ordered index of the selected reachable history.
public struct CommitSearchIndex: Sendable {
    public struct Entry: Sendable {
        public let hash: String
        public let author: String
        public let email: String
        public let message: String
    }

    public let entries: [Entry]

    public func hashes(matching text: String) throws -> [String] {
        var matches: [String] = []
        for (offset, entry) in entries.enumerated() {
            if offset.isMultiple(of: 256) { try Task.checkCancellation() }
            if [entry.author, entry.email, entry.message].contains(where: {
                $0.range(of: text, options: [.caseInsensitive]) != nil
            }) { matches.append(entry.hash) }
        }
        return matches
    }
}

public struct GitCommitSearchIndex: RepositoryCommand {
    public var directory: URL
    public var revisions: [String]
    public init(directory: URL, revisions: [String] = ["HEAD"]) { self.directory = directory; self.revisions = revisions }
    public var isReadOnly: Bool { true }
    public var arguments: [String] {
        ["git", "log", "--topo-order", "--pretty=format:%H%x00%an%x00%ae%x00%B%x00"] + revisions + ["--"]
    }

    public func parse(for output: String) throws -> CommitSearchIndex {
        guard !output.isEmpty else { return CommitSearchIndex(entries: []) }
        var fields = output.components(separatedBy: "\0")
        guard fields.removeLast().isEmpty, fields.count.isMultiple(of: 4) else {
            throw GitExecutionError(description: "Invalid commit records from Git.")
        }
        return CommitSearchIndex(entries: stride(from: 0, to: fields.count, by: 4).map { offset in
            CommitSearchIndex.Entry(hash: fields[offset].trimmingCharacters(in: .newlines),
                                    author: fields[offset + 1], email: fields[offset + 2], message: fields[offset + 3])
        })
    }
}

/// Only materialize the requested page, preserving the index's topological order.
public struct GitCommitSearchPage: InteractiveRepositoryCommand {
    public var directory: URL
    public let hashes: [String]
    public init(directory: URL, hashes: [String]) { self.directory = directory; self.hashes = hashes }
    public var isReadOnly: Bool { true }
    public var arguments: [String] { GitLog(directory: directory, noWalk: true).arguments + ["--stdin"] }
    public var inputs: [String] { hashes }

    public func parse(for output: String) throws -> [Commit] {
        let records = try GitLog(directory: directory).parse(for: output)
        let byHash = Dictionary(uniqueKeysWithValues: records.map { ($0.hash, $0) })
        return hashes.compactMap { byHash[$0] }
    }
}
