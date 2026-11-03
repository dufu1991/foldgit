import Foundation

// MARK: - Working tree status

public struct WorktreeChangeCounts: Hashable, Sendable {
    public var staged = 0
    public var unstaged = 0
    public var untracked = 0
    public var conflicted = 0
    /// Paths with any change. A path staged and modified again counts once.
    public var files = 0

    public init(staged: Int = 0, unstaged: Int = 0, untracked: Int = 0, conflicted: Int = 0, files: Int = 0) {
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
        self.conflicted = conflicted
        self.files = files
    }

    public var isClean: Bool { files == 0 }
}

public struct UpstreamDivergence: Hashable, Sendable {
    public let ahead: Int
    public let behind: Int
}

/// Parsed `git status --porcelain=v2 -z --branch`.
public struct GitWorkingTreeStatus: Hashable, Sendable {
    /// Nil before the first commit.
    public let head: String?
    /// Nil for a detached HEAD.
    public let branch: String?
    public let upstream: UpstreamDivergence?
    public let changes: WorktreeChangeCounts
    public var upstreamReference: String? = nil

    public static func parse(_ output: String) throws -> Self {
        var head: String?
        var branch: String?
        var upstream: UpstreamDivergence?
        var upstreamReference: String?
        var changes = WorktreeChangeCounts()
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let field = fields.next() {
            if field.hasPrefix("# ") {
                let header = field.dropFirst(2).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                let value = header.count == 2 ? String(header[1]) : ""
                switch header[0] {
                case "branch.oid": head = value == "(initial)" ? nil : value
                case "branch.head": branch = value == "(detached)" ? nil : value
                case "branch.upstream": upstreamReference = value
                case "branch.ab":
                    let counts = value.split(separator: " ").map { Int($0.dropFirst()) }
                    guard counts.count == 2, let ahead = counts[0], let behind = counts[1] else { throw invalidStatus }
                    upstream = UpstreamDivergence(ahead: ahead, behind: behind)
                default: break
                }
                continue
            }
            guard let kind = field.first else { continue }
            switch kind {
            case "1", "2":
                let xy = Array(field.dropFirst(2).prefix(2))
                guard xy.count == 2 else { throw invalidStatus }
                if xy[0] != "." { changes.staged += 1 }
                if xy[1] != "." { changes.unstaged += 1 }
                changes.files += 1
                // Renames and copies carry their original path in the next NUL-separated field.
                if kind == "2" { _ = fields.next() }
            case "u":
                changes.conflicted += 1
                changes.files += 1
            case "?":
                changes.untracked += 1
                changes.files += 1
            case "!":
                break
            default:
                throw invalidStatus
            }
        }
        return Self(head: head, branch: branch, upstream: upstream, changes: changes, upstreamReference: upstreamReference)
    }

    private static var invalidStatus: GitExecutionError {
        GitExecutionError(description: NSLocalizedString("Git returned invalid status information.", comment: ""))
    }
}

/// Status reads never take optional locks, so polling a worktree cannot collide with Git running inside it.
public struct GitWorkingTreeStatusQuery: RepositoryCommand {
    public enum Untracked: String, Sendable { case normal, all }
    public var directory: URL
    public var untracked: Untracked
    public init(directory: URL, untracked: Untracked = .normal) {
        self.directory = directory
        self.untracked = untracked
    }
    public var isReadOnly: Bool { true }
    public var arguments: [String] {
        ["git", "--no-optional-locks", "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=\(untracked.rawValue)"]
    }
    public func parse(for standardOutput: String) throws -> GitWorkingTreeStatus { try GitWorkingTreeStatus.parse(standardOutput) }
}

/// Every ignored file, with its complete repository-relative path.
public struct GitIgnoredEntriesQuery: RepositoryCommand {
    public var directory: URL
    public init(directory: URL) { self.directory = directory }
    public var isReadOnly: Bool { true }
    public var arguments: [String] {
        ["git", "--no-optional-locks", "ls-files", "--others", "--ignored", "--exclude-standard", "-z"]
    }
    public func parse(for standardOutput: String) -> [String] {
        Array(Set(standardOutput.split(separator: "\0").map(String.init))).sorted()
    }
}

// MARK: - Operations in progress

public enum GitPendingOperation: String, Sendable {
    case merge, cherryPick, revert, rebase, bisect

    private static let markers: [(String, Self)] = [
        ("MERGE_HEAD", .merge), ("CHERRY_PICK_HEAD", .cherryPick), ("REVERT_HEAD", .revert),
        ("rebase-merge", .rebase), ("rebase-apply", .rebase), ("BISECT_LOG", .bisect),
    ]
    /// Entries in a worktree's own Git directory that start or end an operation.
    public static let markerNames = markers.map(\.0) + ["sequencer"]

    /// Every marker lives in the worktree's own Git directory, so one directory read replaces a Git process per marker.
    static func detect(inGitDirectory directory: URL) -> Self? {
        let exists = { (name: String) in FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) }
        if let operation = markers.first(where: { exists($0.0) })?.1 { return operation }
        // A multi-commit cherry-pick or revert stays in progress between its commits without a *_HEAD file.
        guard exists("sequencer") else { return nil }
        let todo = (try? String(contentsOf: directory.appendingPathComponent("sequencer/todo"), encoding: .utf8)) ?? ""
        return todo.hasPrefix("revert") ? .revert : .cherryPick
    }

    static func detect(using session: GitRuntime.Session) async throws -> Self? {
        let gitDirectory = try await session.run(GitAbsoluteGitDirectory(directory: session.directory))
        return detect(inGitDirectory: URL(fileURLWithPath: gitDirectory, isDirectory: true))
    }
}

struct GitAbsoluteGitDirectory: RepositoryCommand {
    var directory: URL
    var isReadOnly: Bool { true }
    var arguments: [String] { ["git", "rev-parse", "--absolute-git-dir"] }
    func parse(for standardOutput: String) -> String { standardOutput.trimmingCharacters(in: .newlines) }
}

// MARK: - Trunk

/// The branch work is expected to land on, and its remote counterpart when one exists.
public struct TrunkReference: Hashable, Sendable {
    /// Full local reference, such as `refs/heads/main`.
    public let local: String?
    /// Full remote reference, such as `refs/remotes/origin/main`.
    public let remote: String?

    public init(local: String?, remote: String?) {
        self.local = local
        self.remote = remote
    }

    /// Divergence is shown against the remote trunk, because hosted merges land there first.
    public var comparison: String? { remote ?? local }
    public var displayName: String? { comparison.map(Self.shortName) }
    var candidates: [String] { [local, remote].compactMap { $0 } }

    static func shortName(_ reference: String) -> String {
        for prefix in ["refs/heads/", "refs/remotes/"] where reference.hasPrefix(prefix) { return String(reference.dropFirst(prefix.count)) }
        return reference
    }

    /// Resolves an explicit branch, then `origin/HEAD`, then `main` or `master`, then the main worktree's branch.
    public static func resolve(in directory: URL, preferred: String? = nil, mainWorktreeBranch: String? = nil) async throws -> Self? {
        try await GitRuntime.read(at: directory, readOnly: true) { session in
            let originHead = try await session.run(TrunkOriginHead(directory: directory))
            var names: [String] = []
            if let preferred, !preferred.isEmpty { names.append(preferred) }
            if originHead.hasPrefix("refs/remotes/origin/") { names.append(String(originHead.dropFirst(20))) }
            names += ["main", "master"]
            if let mainWorktreeBranch { names.append(mainWorktreeBranch) }
            // Only the candidates are listed, so repositories with thousands of branches stay cheap to poll.
            let refs = try await session.run(TrunkRefs(directory: directory,
                references: names.flatMap { ["refs/heads/\($0)", "refs/remotes/origin/\($0)"] }))
            for name in names {
                let local = "refs/heads/\(name)"
                let remoteOnly = "refs/remotes/origin/\(name)"
                guard refs[local] != nil || refs[remoteOnly] != nil else { continue }
                var remote: String?
                if let upstream = refs[local] {
                    // A configured upstream may be pruned or never fetched; only an existing ref can be compared.
                    // Without a usable upstream, a same-named branch on origin is still the trunk's remote copy.
                    remote = upstream ?? (refs[remoteOnly] != nil ? remoteOnly : nil)
                } else {
                    remote = remoteOnly
                }
                return Self(local: refs[local] != nil ? local : nil, remote: remote)
            }
            return nil
        }
    }
}

/// Maps each existing reference to its upstream, which is nil when none is configured or it no longer exists.
private struct TrunkRefs: RepositoryCommand {
    var directory: URL
    let references: [String]
    var isReadOnly: Bool { true }
    var arguments: [String] { ["git", "for-each-ref", "--format=%(refname)%00%(upstream)%00%(upstream:track)"] + references }
    func parse(for standardOutput: String) -> [String: String?] {
        var refs: [String: String?] = [:]
        for line in standardOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, references.contains(fields[0]) else { continue }
            refs[fields[0]] = fields[1].isEmpty || fields[2] == "[gone]" ? String?.none : fields[1]
        }
        return refs
    }
}

/// `for-each-ref` succeeds without a match, so a missing `origin/HEAD` is not logged as a failed command.
private struct TrunkOriginHead: RepositoryCommand {
    var directory: URL
    var isReadOnly: Bool { true }
    var arguments: [String] { ["git", "for-each-ref", "--format=%(symref)", "refs/remotes/origin/HEAD"] }
    func parse(for standardOutput: String) -> String { standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Integration

public enum WorktreeIntegration: Hashable, Sendable {
    /// No trunk, no commit, or the comparison failed.
    case unknown
    case notIntegrated
    /// The commit is reachable from the trunk: fast-forwards, merge commits and linear landings.
    case ancestor
    /// Merging the commit into the trunk changes nothing: squash and rebase merges.
    case contentMerged

    public var isIntegrated: Bool { self == .ancestor || self == .contentMerged }
}

public struct TrunkComparison: Hashable, Sendable {
    /// Short name of the reference used for ahead and behind, such as `origin/main`.
    public let reference: String
    public let ahead: Int
    public let behind: Int
    public let integration: WorktreeIntegration
    /// Short name of the reference that contains the commit. It differs from `reference`
    /// when the work is merged into the local trunk but not pushed yet.
    public let integratedInto: String?
    /// HEAD has not moved since its branch or detached worktree was created. Such a worktree is an ancestor
    /// of the trunk because no work has started, not because work was merged.
    public let isUnstarted: Bool

    public init(reference: String, ahead: Int, behind: Int, integration: WorktreeIntegration, integratedInto: String? = nil,
                isUnstarted: Bool = false) {
        self.reference = reference
        self.ahead = ahead
        self.behind = behind
        self.integration = integration
        self.integratedInto = integratedInto
        self.isUnstarted = isUnstarted
    }

    /// Integrated work that was actually done here, as opposed to a worktree created on the trunk and left untouched.
    public var hasMergedWork: Bool { integration.isIntegrated && !isUnstarted }
}

public enum WorktreeIntegrationCheck {
    /// Compares `commit` with the trunk. It is integrated if either the local or the remote trunk contains it.
    /// Pass the checked-out `branch` so a worktree that never committed is told apart from merged work.
    public static func compare(_ commit: String, with trunk: TrunkReference, in directory: URL,
                               branch: String? = nil) async throws -> TrunkComparison? {
        guard let comparison = trunk.comparison else { return nil }
        return try await GitRuntime.read(at: directory, readOnly: true) { session in
            let counts = try await session.run(IntegrationGit(directory: directory,
                args: ["rev-list", "--left-right", "--count", "\(comparison)...\(commit)"]))
            let parts = counts.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            guard parts.count == 2 else { throw GitExecutionError(description: NSLocalizedString("Git returned invalid commit counts.", comment: "")) }
            let (behind, ahead) = (parts[0], parts[1])
            var integration = WorktreeIntegration.notIntegrated
            var integratedInto: String?
            if ahead == 0 {
                (integration, integratedInto) = (.ancestor, comparison)
            } else {
                for reference in trunk.candidates where reference != comparison {
                    let count = try await session.run(IntegrationGit(directory: directory, args: ["rev-list", "--count", "\(reference)..\(commit)"]))
                    if count.trimmingCharacters(in: .whitespacesAndNewlines) == "0" { (integration, integratedInto) = (.ancestor, reference); break }
                }
                if integration != .ancestor {
                    for reference in trunk.candidates {
                        if try await contentMerged(commit, into: reference, using: session) {
                            (integration, integratedInto) = (.contentMerged, reference)
                            break
                        }
                    }
                }
            }
            let unstarted = integration == .ancestor ? await isUnstarted(commit, branch: branch, using: session) : false
            return TrunkComparison(reference: TrunkReference.shortName(comparison), ahead: ahead, behind: behind,
                                   integration: integration, integratedInto: integratedInto.map(TrunkReference.shortName),
                                   isUnstarted: unstarted)
        }
    }

    /// True when every reflog entry of the branch, or of a detached HEAD, points at `commit`. A missing reflog
    /// proves nothing, so it reads as started and keeps the plain ancestry result.
    static func isUnstarted(_ commit: String, branch: String?, using session: GitRuntime.Session) async -> Bool {
        let reference = branch.map { "refs/heads/" + $0 } ?? "HEAD"
        guard let log = try? await session.run(IntegrationGit(directory: session.directory,
                args: ["log", "--walk-reflogs", "--format=%H", "-n", "200", reference, "--"])) else { return false }
        let entries = log.split(whereSeparator: \.isNewline)
        return !entries.isEmpty && entries.allSatisfy { $0 == commit }
    }

    /// A conflict, or a Git too old for `merge-tree --write-tree`, reads as not merged.
    static func contentMerged(_ commit: String, into reference: String, using session: GitRuntime.Session) async throws -> Bool {
        guard let merged = try? await session.run(IntegrationGit(directory: session.directory,
                args: ["merge-tree", "--write-tree", "--no-messages", reference, commit])) else { return false }
        let tree = try await session.run(IntegrationGit(directory: session.directory,
            args: ["rev-parse", "--verify", "--end-of-options", reference + "^{tree}"]))
        let mergedTree = merged.split(whereSeparator: \.isNewline).first.map(String.init)
        return mergedTree == tree.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct IntegrationGit: RepositoryCommand {
    var directory: URL
    let args: [String]
    var isReadOnly: Bool { true }
    var arguments: [String] { ["git"] + args }
    func parse(for standardOutput: String) -> String { standardOutput }
}

// MARK: - Combined status

/// Trunk comparisons keyed by worktree, HEAD and trunk tips. Polling reruns only the cheap status read until one of them moves.
public actor TrunkComparisonCache {
    private var values: [String: TrunkComparison] = [:]
    public init() {}
    func value(for key: String) -> TrunkComparison? { values[key] }
    func store(_ value: TrunkComparison, for key: String) {
        if values.count > 512 { values.removeAll() }
        values[key] = value
    }
}

public struct WorktreeStatus: Hashable, Sendable {
    public let working: GitWorkingTreeStatus
    public let operation: GitPendingOperation?
    public let trunk: TrunkComparison?

    public var head: String? { working.head }
    public var changes: WorktreeChangeCounts { working.changes }
    public var upstream: UpstreamDivergence? { working.upstream }
    public var isClean: Bool { changes.isClean && operation == nil }
    /// Integrated but unstarted worktrees still qualify: removing them loses nothing, but they are never preselected.
    public var canBeCleanedUp: Bool { isClean && trunk?.integration.isIntegrated == true }

    public init(working: GitWorkingTreeStatus, operation: GitPendingOperation?, trunk: TrunkComparison?) {
        self.working = working
        self.operation = operation
        self.trunk = trunk
    }

    public static func read(_ directory: URL, trunk: TrunkReference?, untracked: GitWorkingTreeStatusQuery.Untracked = .normal,
                            cache: TrunkComparisonCache? = nil) async throws -> Self {
        let (working, operation, tips) = try await GitRuntime.read(at: directory, readOnly: true) { session in
            let working = try await session.run(GitWorkingTreeStatusQuery(directory: directory, untracked: untracked))
            let operation = try await GitPendingOperation.detect(using: session)
            var tips: String?
            if let trunk, working.head != nil {
                tips = try? await session.run(IntegrationGit(directory: directory,
                    args: ["rev-parse", "--end-of-options"] + trunk.candidates))
            }
            return (working, operation, tips)
        }
        // Without readable trunk tips there is nothing to compare, but changes and pending operations still count.
        guard let head = working.head, let trunk, let tips else { return Self(working: working, operation: operation, trunk: nil) }
        let key = [RepositoryLocation.key(for: directory), head, working.branch ?? "", tips].joined(separator: "|")
        if let cached = await cache?.value(for: key) { return Self(working: working, operation: operation, trunk: cached) }
        let comparison = try? await WorktreeIntegrationCheck.compare(head, with: trunk, in: directory, branch: working.branch)
        if let comparison { await cache?.store(comparison, for: key) }
        return Self(working: working, operation: operation, trunk: comparison)
    }
}
