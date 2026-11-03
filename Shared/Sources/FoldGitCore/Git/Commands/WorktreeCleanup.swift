import Foundation
internal import Subprocess

/// A linked worktree whose commit is already on the trunk and whose folder holds nothing Git would refuse to remove.
public struct WorktreeCleanupCandidate: Hashable, Sendable, Identifiable {
    public let tree: GitWorktree
    public let head: String
    public let trunkReference: TrunkReference
    public let trunk: TrunkComparison
    /// Complete paths of all ignored files. `git worktree remove` deletes them without asking.
    public let ignoredEntries: [String]
    /// Latest change to the worktree's HEAD, index or reflog.
    public let lastActivity: Date?
    public var id: URL { tree.id }

    public func isRecentlyActive(at now: Date = .now) -> Bool {
        lastActivity.map { now.timeIntervalSince($0) < WorktreeCleanup.recentActivityInterval } ?? false
    }

    /// Every worktree containing ignored files or recent activity, or one where no work was ever committed,
    /// needs an explicit choice.
    public func isSelectedByDefault(at now: Date = .now) -> Bool {
        ignoredEntries.isEmpty && !isRecentlyActive(at: now) && !trunk.isUnstarted
    }

    /// Ignored files grouped by their top-level entry, largest groups first. A directory such as
    /// `node_modules` holds thousands of files, which cannot be listed one by one.
    public var ignoredGroups: [IgnoredGroup] { IgnoredGroup.groups(ignoredEntries) }
}

public struct IgnoredGroup: Hashable, Sendable {
    /// A top-level file name, or a directory name with a trailing slash.
    public let name: String
    public let files: Int

    static func groups(_ paths: [String]) -> [Self] {
        var counts: [String: Int] = [:]
        for path in paths {
            let parts = path.split(separator: "/", maxSplits: 1)
            counts[parts.count == 2 ? parts[0] + "/" : path, default: 0] += 1
        }
        return counts.map { Self(name: $0.key, files: $0.value) }
            .sorted { $0.files != $1.files ? $0.files > $1.files : $0.name < $1.name }
    }
}

public enum WorktreeBranchOutcome: Hashable, Sendable {
    case deleted
    case notRequested
    case keptDetached
    /// Squash and rebase merges leave a branch that only `git branch -D` removes. FoldGit never forces it.
    case keptContentMerged
    case keptTrunk
    case keptCheckedOut
    case failed(String)
}

public enum WorktreeCleanup {
    public static let recentActivityInterval: TimeInterval = 15 * 60

    public static func candidates(in repository: URL, preferredTrunk: String? = nil) async throws -> [WorktreeCleanupCandidate] {
        let trees = try await GitRuntime.run(GitWorktreeList(directory: repository))
        guard let trunk = try await TrunkReference.resolve(in: repository, preferred: preferredTrunk,
                                                           mainWorktreeBranch: trees.first(where: \.isMain)?.branch) else { return [] }
        let trunkBranch = trunk.local.map(TrunkReference.shortName)
        // Only a worktree that has the local trunk branch checked out is skipped; detached worktrees still qualify.
        let eligible = trees.filter { isRemovable($0) && (trunkBranch == nil || $0.branch != trunkBranch) }
        var found: [URL: WorktreeCleanupCandidate] = [:]
        var start = eligible.startIndex
        while start < eligible.endIndex {
            let batch = eligible[start..<min(start + concurrentReads, eligible.endIndex)]
            start = batch.endIndex
            try await withThrowingTaskGroup(of: WorktreeCleanupCandidate?.self) { group in
                for tree in batch { group.addTask { try await candidate(tree, trunk: trunk) } }
                for try await candidate in group { if let candidate { found[candidate.id] = candidate } }
            }
        }
        return eligible.compactMap { found[$0.id] }
    }

    /// Worktrees are read a few at a time, so a repository with many worktrees does not start dozens of Git processes.
    static let concurrentReads = 4

    private static func candidate(_ tree: GitWorktree, trunk: TrunkReference) async throws -> WorktreeCleanupCandidate? {
        guard let status = try? await WorktreeStatus.read(tree.url, trunk: trunk, untracked: .all),
              status.canBeCleanedUp, let head = status.head, let comparison = status.trunk else { return nil }
        let ignored = try await GitRuntime.run(GitIgnoredEntriesQuery(directory: tree.url))
        return WorktreeCleanupCandidate(tree: tree, head: head, trunkReference: trunk, trunk: comparison,
                                        ignoredEntries: ignored, lastActivity: try? await lastActivity(of: tree.url))
    }

    /// Checks the candidate again, removes it without force, then deletes its branch only when Git can prove it merged.
    public static func remove(_ candidate: WorktreeCleanupCandidate, deletingBranch: Bool) async throws -> WorktreeBranchOutcome {
        let trees = try await GitRuntime.run(GitWorktreeList(directory: candidate.tree.url))
        guard let current = trees.first(where: { $0.id == candidate.id }), isRemovable(current),
              current.branch == candidate.tree.branch, current.head == candidate.head else { throw WorktreeCleanupError.changed }
        let trunkBranch = candidate.trunkReference.local.map(TrunkReference.shortName)
        let others = trees.filter { $0.id != candidate.id && !$0.isBare && !$0.isPrunable && FileManager.default.fileExists(atPath: $0.url.path) }
        // `git branch -d` checks against the current branch, so prefer a worktree on the trunk.
        guard let runner = others.first(where: { $0.branch != nil && $0.branch == trunkBranch }) ?? others.first else {
            throw WorktreeCleanupError.noRemainingWorktree
        }
        // Keep Git's HEAD and referent locks from the final check through removal. A detached
        // commit cannot land between the status snapshot and deletion and lose its only reference.
        let integration = try await withLockedHead(candidate) {
            let status = try await WorktreeStatus.read(candidate.tree.url, trunk: candidate.trunkReference, untracked: .all)
            guard status.head == candidate.head, status.working.branch == candidate.tree.branch,
                  status.canBeCleanedUp, let integration = status.trunk?.integration else {
                throw WorktreeCleanupError.changed
            }
            let ignored = try await GitRuntime.run(GitIgnoredEntriesQuery(directory: candidate.tree.url))
            guard Set(ignored).isSubset(of: Set(candidate.ignoredEntries)) else {
                throw WorktreeCleanupError.ignoredFilesChanged
            }
            try Task.checkCancellation()
            try await GitRuntime.run(GitWorktreeCommand(directory: runner.url, operation: .remove(candidate.tree.url)))
            return integration
        }

        guard deletingBranch else { return .notRequested }
        guard let branch = candidate.tree.branch else { return .keptDetached }
        guard branch != trunkBranch else { return .keptTrunk }
        guard integration == .ancestor else { return .keptContentMerged }
        let remaining = try await GitRuntime.run(GitWorktreeList(directory: runner.url))
        guard !remaining.contains(where: { $0.branch == branch }) else { return .keptCheckedOut }
        do {
            try await GitRuntime.run(GitBranchDelete(directory: runner.url, branchName: branch))
            return .deleted
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// A prepared verification transaction locks HEAD and its symbolic target without changing
    /// either reference. Git releases the locks on abort, EOF, cancellation or an error.
    static func withLockedHead<Value: Sendable>(_ candidate: WorktreeCleanupCandidate,
        operation: @Sendable () async throws -> Value) async throws -> Value {
        var options = Subprocess.PlatformOptions()
        #if !os(Windows)
        // Give Git time to remove its lock files before Subprocess escalates cancellation.
        options.teardownSequence = [.send(signal: .terminate, allowedDurationToNextStep: .seconds(2))]
        #endif
        let result = try await Subprocess.run(
            .name("git"), arguments: ["update-ref", "--stdin"],
            environment: .inherit.updating(["LC_ALL": "en_US.UTF-8", "LANG": "en_US.UTF-8", "GIT_TERMINAL_PROMPT": "0"]),
            workingDirectory: .init(candidate.tree.url.path),
            platformOptions: options,
            input: .inputWriter, output: .sequence, error: .discarded
        ) { execution in
            var responses = execution.standardOutput.strings().makeAsyncIterator()
            _ = try await execution.standardInputWriter.write(Array("start\nverify HEAD \(candidate.head)\nprepare\n".utf8))
            guard try await responses.next() == "start: ok",
                  try await responses.next() == "prepare: ok" else { throw WorktreeCleanupError.changed }
            try Task.checkCancellation()
            let value = try await operation()
            _ = try await execution.standardInputWriter.write(Array("abort\n".utf8))
            guard try await responses.next() == "abort: ok" else { throw WorktreeCleanupError.changed }
            try await execution.standardInputWriter.finish()
            return value
        }
        guard result.terminationStatus.isSuccess else { throw WorktreeCleanupError.changed }
        return result.closureResult
    }

    static func isRemovable(_ tree: GitWorktree) -> Bool {
        !tree.isMain && !tree.isBare && !tree.isLocked && !tree.isPrunable && FileManager.default.fileExists(atPath: tree.url.path)
    }

    static func lastActivity(of directory: URL) async throws -> Date? {
        let gitDirectory = try await GitRuntime.run(GitAbsoluteGitDirectory(directory: directory))
        let base = URL(fileURLWithPath: gitDirectory, isDirectory: true)
        return ["HEAD", "index", "logs/HEAD"].compactMap { name in
            (try? FileManager.default.attributesOfItem(atPath: base.appendingPathComponent(name).path))?[.modificationDate] as? Date
        }.max()
    }
}

public enum WorktreeCleanupError: LocalizedError, Equatable {
    case changed, ignoredFilesChanged, noRemainingWorktree
    public var errorDescription: String? {
        switch self {
        case .changed: NSLocalizedString("The worktree changed after the preview. It was kept.", comment: "")
        case .ignoredFilesChanged: NSLocalizedString("New ignored files appeared in the worktree after the preview. It was kept.", comment: "")
        case .noRemainingWorktree: NSLocalizedString("Another worktree of this repository is required to remove this one.", comment: "")
        }
    }
}
