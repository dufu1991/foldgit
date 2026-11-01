import Foundation

/// A linked worktree whose commit is already on the trunk and whose folder holds nothing Git would refuse to remove.
public struct WorktreeCleanupCandidate: Hashable, Sendable, Identifiable {
    public let tree: GitWorktree
    public let head: String
    public let trunkReference: TrunkReference
    public let trunk: TrunkComparison
    /// Top-level ignored paths. `git worktree remove` deletes them without asking.
    public let ignoredEntries: [String]
    /// Latest change to the worktree's HEAD, index or reflog.
    public let lastActivity: Date?
    public var id: URL { tree.id }

    /// Ignored paths that a build or install cannot recreate, such as `.env.local`.
    public var notableIgnored: [String] { ignoredEntries.filter { !WorktreeCleanup.regenerableEntries.contains($0) } }

    public func isRecentlyActive(at now: Date = .now) -> Bool {
        lastActivity.map { now.timeIntervalSince($0) < WorktreeCleanup.recentActivityInterval } ?? false
    }

    /// Worktrees with irreplaceable ignored files or recent activity need an explicit choice.
    public func isSelectedByDefault(at now: Date = .now) -> Bool { notableIgnored.isEmpty && !isRecentlyActive(at: now) }
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
    public static let regenerableEntries: Set<String> = [
        "node_modules", ".build", "DerivedData", "dist", "build", ".next", ".turbo", ".venv", "__pycache__", "target", ".gradle", ".DS_Store",
    ]
    public static let recentActivityInterval: TimeInterval = 15 * 60

    public static func candidates(in repository: URL, preferredTrunk: String? = nil) async throws -> [WorktreeCleanupCandidate] {
        let trees = try await GitRuntime.run(GitWorktreeList(directory: repository))
        guard let trunk = try await TrunkReference.resolve(in: repository, preferred: preferredTrunk,
                                                           mainWorktreeBranch: trees.first(where: \.isMain)?.branch) else { return [] }
        let trunkBranch = trunk.local.map(TrunkReference.shortName)
        var candidates: [WorktreeCleanupCandidate] = []
        for tree in trees where isRemovable(tree) && tree.branch != trunkBranch {
            guard let status = try? await WorktreeStatus.read(tree.url, trunk: trunk, untracked: .all),
                  status.canBeCleanedUp, let head = status.head, let comparison = status.trunk else { continue }
            let ignored = try await GitRuntime.run(GitIgnoredEntriesQuery(directory: tree.url))
            candidates.append(WorktreeCleanupCandidate(tree: tree, head: head, trunkReference: trunk, trunk: comparison,
                                                       ignoredEntries: ignored, lastActivity: try? await lastActivity(of: tree.url)))
        }
        return candidates
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
        let status = try await WorktreeStatus.read(candidate.tree.url, trunk: candidate.trunkReference, untracked: .all)
        guard status.head == candidate.head, status.canBeCleanedUp, let integration = status.trunk?.integration else {
            throw WorktreeCleanupError.changed
        }
        let ignored = try await GitRuntime.run(GitIgnoredEntriesQuery(directory: candidate.tree.url))
        guard Set(ignored.filter { !regenerableEntries.contains($0) }).isSubset(of: Set(candidate.notableIgnored)) else {
            throw WorktreeCleanupError.ignoredFilesChanged
        }
        try await GitRuntime.run(GitWorktreeCommand(directory: runner.url, operation: .remove(candidate.tree.url)))

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

private struct GitAbsoluteGitDirectory: RepositoryCommand {
    var directory: URL
    var isReadOnly: Bool { true }
    var arguments: [String] { ["git", "rev-parse", "--absolute-git-dir"] }
    func parse(for standardOutput: String) -> String { standardOutput.trimmingCharacters(in: .newlines) }
}

public enum WorktreeCleanupError: LocalizedError {
    case changed, ignoredFilesChanged, noRemainingWorktree
    public var errorDescription: String? {
        switch self {
        case .changed: NSLocalizedString("The worktree changed after the preview. It was kept.", comment: "")
        case .ignoredFilesChanged: NSLocalizedString("New ignored files appeared in the worktree after the preview. It was kept.", comment: "")
        case .noRemainingWorktree: NSLocalizedString("Another worktree of this repository is required to remove this one.", comment: "")
        }
    }
}
