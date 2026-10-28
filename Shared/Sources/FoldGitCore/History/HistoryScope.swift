import Foundation

public enum HistoryScope: String, CaseIterable, Sendable {
    case currentBranch, allCommits
}

public struct GitRevisionHashes: RepositoryCommand {
    public var directory: URL
    public let revisions: [String]

    public init(directory: URL, revisions: [String]) {
        self.directory = directory
        self.revisions = revisions
    }

    public var isReadOnly: Bool { true }
    public var arguments: [String] { ["git", "rev-list", "--topo-order"] + revisions + ["--"] }
    public func parse(for output: String) -> [String] { output.split(separator: "\n").map(String.init) }
}

/// Pin each history query to the same fetched ref tips, including detached HEAD.
public struct HistorySnapshot: Sendable {
    public let headHash: String?
    public let tips: [String]
    public let outsideCurrentBranch: Set<String>
    public let incoming: [String]
    public let incomingHashes: Set<String>
    public let outgoing: Set<String>

    public func revisions(for scope: HistoryScope) -> [String] {
        scope == .currentBranch ? headHash.map { [$0] } ?? [] : tips
    }

    public static func read(in directory: URL) async throws -> Self {
        async let headResult = GitRuntime.run(arguments: ["git", "rev-parse", "--revs-only", "HEAD"],
                                             currentDirectoryURL: directory, readOnly: true)
        async let branchResult = GitRuntime.run(GitCurrentBranch(directory: directory))
        async let refsResult = GitRuntime.run(arguments: [
            "git", "for-each-ref", "--format=%(refname)%00%(objectname)%00%(upstream)",
            "refs/heads", "refs/remotes", "refs/tags",
        ], currentDirectoryURL: directory, readOnly: true)
        let (headOutput, branch, refsOutput) = try await (headResult, branchResult, refsResult)
        let head = headOutput.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let headHash = head.isEmpty ? nil : head
        var refs: [String: String] = [:]
        var upstream: String?
        for line in refsOutput.standardOutput.split(separator: "\n") {
            let fields = line.components(separatedBy: "\0")
            guard fields.count == 3 else { throw GitExecutionError(description: "Invalid history references from Git.") }
            refs[fields[0]] = fields[1]
            if let branch, fields[0] == "refs/heads/\(branch)", !fields[2].isEmpty { upstream = fields[2] }
        }
        let tips = Array(Set(refs.values).union(headHash.map { [$0] } ?? [])).sorted()
        let upstreamHash = upstream.flatMap { refs[$0] }
        let incomingRevisions = upstreamHash.map { [$0] + (headHash.map { ["^\($0)"] } ?? []) } ?? []
        let outgoingRevisions = headHash.flatMap { head in upstreamHash.map { [head, "^\($0)"] } } ?? []
        async let outside = hashes(in: directory, revisions: headHash.map { tips + ["--not", $0] } ?? tips)
        async let incoming = hashes(in: directory, revisions: incomingRevisions)
        async let outgoing = hashes(in: directory, revisions: outgoingRevisions)
        let (outsideHashes, incomingHashes, outgoingHashes) = try await (outside, incoming, outgoing)
        return Self(headHash: headHash, tips: tips, outsideCurrentBranch: Set(outsideHashes),
                    incoming: incomingHashes, incomingHashes: Set(incomingHashes), outgoing: Set(outgoingHashes))
    }

    private static func hashes(in directory: URL, revisions: [String]) async throws -> [String] {
        guard !revisions.isEmpty else { return [] }
        return try await GitRuntime.run(GitRevisionHashes(directory: directory, revisions: revisions))
    }
}
