import Foundation

public struct GitMergeConflict: Hashable, Identifiable, Sendable {
    public let path: String
    public let targetExists: Bool
    public let incomingExists: Bool
    public var id: String { path }
}

public struct GitMergeState: Equatable, Sendable {
    public let directory: URL
    public let incomingCommits: [String]
    public let conflicts: [GitMergeConflict]
    public let hasUnstagedChanges: Bool
    public var isMerging: Bool { !incomingCommits.isEmpty }
    public var canContinue: Bool { isMerging && conflicts.isEmpty && !hasUnstagedChanges }

    public static func read(in directory: URL) async throws -> Self {
        try await GitRuntime.read(at: directory, readOnly: true) { try await read(using: $0) }
    }

    static func read(using session: GitRuntime.Session) async throws -> Self {
        let path = try await session.run(GitRevParse(directory: session.directory, gitPath: "MERGE_HEAD"))
        let url = URL(fileURLWithPath: path, relativeTo: session.directory.appendingPathComponent("", isDirectory: true)).standardizedFileURL
        let heads = FileManager.default.fileExists(atPath: url.path)
            ? try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init) : []
        let unmerged = try await session.run(MergeGit(directory: session.directory, args: ["ls-files", "--unmerged", "-z"]))
        let unstaged = try await session.run(MergeGit(directory: session.directory, args: ["diff", "--name-only", "-z"]))
        return Self(directory: session.directory, incomingCommits: heads, conflicts: try parseConflicts(unmerged), hasUnstagedChanges: !unstaged.isEmpty)
    }

    public static func parseConflicts(_ output: String) throws -> [GitMergeConflict] {
        var stages: [String: Set<Int>] = [:]
        for record in output.split(separator: "\0") {
            guard let tab = record.firstIndex(of: "\t"),
                  let stage = Int(record[..<tab].split(separator: " ").last ?? ""), (1...3).contains(stage) else {
                throw MergeWorkflowError.invalidConflicts
            }
            stages[String(record[record.index(after: tab)...]), default: []].insert(stage)
        }
        return stages.keys.sorted().map { path in
            GitMergeConflict(path: path, targetExists: stages[path]!.contains(2), incomingExists: stages[path]!.contains(3))
        }
    }
}

public enum MergeResolution: Sendable { case target, incoming, edited, delete }

public enum GitMergeWorkflow {
    public static func resolve(_ path: String, choosing resolution: MergeResolution, in directory: URL) async throws {
        try await GitRuntime.read(at: directory) { session in
            let state = try await GitMergeState.read(using: session)
            guard state.isMerging, let conflict = state.conflicts.first(where: { $0.path == path }) else { throw MergeWorkflowError.noMerge }
            switch resolution {
            case .target, .incoming:
                let exists = resolution == .target ? conflict.targetExists : conflict.incomingExists
                if exists {
                    _ = try await session.run(MergeGit(directory: directory, args: ["checkout", resolution == .target ? "--ours" : "--theirs", "--", path]))
                    try await session.run(GitAddPathspec(directory: directory, pathspec: path))
                } else {
                    _ = try await session.run(MergeGit(directory: directory, args: ["rm", "--", path]))
                }
            case .edited:
                let url = directory.appendingPathComponent(path)
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                if attributes?[.type] as? FileAttributeType == .typeRegular,
                   let content = String(data: try Data(contentsOf: url), encoding: .utf8),
                   content.split(separator: "\n", omittingEmptySubsequences: false).contains(where: {
                       $0.hasPrefix("<<<<<<< ") || $0.hasPrefix(">>>>>>> ") || $0 == "======="
                   }) { throw MergeWorkflowError.conflictMarkers }
                try await session.run(GitAddPathspec(directory: directory, pathspec: path))
            case .delete:
                _ = try await session.run(MergeGit(directory: directory, args: ["rm", "--", path]))
            }
        }
    }

    public static func continueMerge(in directory: URL) async throws {
        try await GitRuntime.read(at: directory) { session in
            guard try await GitMergeState.read(using: session).canContinue else { throw MergeWorkflowError.unresolved }
            _ = try await session.run(MergeGit(directory: directory, args: ["commit", "--no-edit"]))
        }
    }

    public static func abort(in directory: URL) async throws {
        try await GitRuntime.read(at: directory) { session in
            guard try await GitMergeState.read(using: session).isMerging else { throw MergeWorkflowError.noMerge }
            _ = try await session.run(MergeGit(directory: directory, args: ["merge", "--abort"]))
        }
    }
}

public struct WorktreeCompletionPlan: Equatable, Sendable {
    public let source: URL
    public let sourceBranch: String
    public let sourceCommit: String
    public let target: URL
    public let targetBranch: String
    public let targetCommit: String
    public let originalTargetBranch: String?
    public let commitCount: Int
    public var switchesTargetBranch: Bool { originalTargetBranch != targetBranch }
}

public enum WorktreeMergeResult: Sendable {
    case merged
    case inProgress(GitMergeState, diagnostic: String)
}

public enum WorktreeCompletion {
    public static func prepare(source: URL, targetBranch: String) async throws -> WorktreeCompletionPlan {
        let trees = try await GitRuntime.run(GitWorktreeList(directory: source))
        let identity = source.standardizedFileURL.resolvingSymlinksInPath()
        guard let sourceTree = trees.first(where: { $0.id == identity }), !sourceTree.isMain, !sourceTree.isBare,
              let sourceBranch = sourceTree.branch, let sourceCommit = sourceTree.head else { throw MergeWorkflowError.linkedBranchRequired }
        guard sourceBranch != targetBranch else { throw MergeWorkflowError.sameBranch }
        let destination = trees.first { $0.branch == targetBranch && !$0.isPrunable && !$0.isBare }
            ?? trees.first { $0.isMain && $0.id != identity && !$0.isPrunable }
        guard let destination else { throw MergeWorkflowError.targetWorktreeRequired }
        try await requireClean(source)
        let pendingMerge = try await GitMergeState.read(in: destination.url)
        if pendingMerge.isMerging {
            guard pendingMerge.incomingCommits == [sourceCommit], destination.branch == targetBranch else {
                throw MergeWorkflowError.operationInProgress
            }
        } else {
            try await requireClean(destination.url)
        }
        let targetCommit = try await revision("refs/heads/\(targetBranch)", in: source)
        let count = try await GitRuntime.run(MergeGit(directory: source, args: ["rev-list", "--count", "\(targetCommit)..\(sourceCommit)"]))
        guard let commitCount = Int(count.trimmingCharacters(in: .newlines)) else { throw MergeWorkflowError.invalidConflicts }
        return WorktreeCompletionPlan(source: identity, sourceBranch: sourceBranch, sourceCommit: sourceCommit,
            target: destination.url, targetBranch: targetBranch, targetCommit: targetCommit,
            originalTargetBranch: destination.branch, commitCount: commitCount)
    }

    public static func merge(_ plan: WorktreeCompletionPlan) async throws -> WorktreeMergeResult {
        try await validateSource(plan)
        return try await GitRuntime.read(at: plan.target) { session in
            try await requireClean(using: session)
            let current = try await session.run(GitBranch(directory: plan.target)).current
            guard (current?.isDetached == true ? nil : current?.name) == plan.originalTargetBranch,
                  try await revision("refs/heads/\(plan.targetBranch)", using: session) == plan.targetCommit else { throw MergeWorkflowError.changed }
            if plan.switchesTargetBranch { try await session.run(GitSwitch(directory: plan.target, branchName: plan.targetBranch)) }
            do {
                _ = try await session.run(MergeGit(directory: plan.target, args: ["merge", "--no-edit", "--commit", "--no-squash", "-m",
                    "Merge branch '\(plan.sourceBranch)' into \(plan.targetBranch)", "--", plan.sourceCommit]))
                let state = try await GitMergeState.read(using: session)
                if state.isMerging { return .inProgress(state, diagnostic: "") }
                let remaining = try await session.run(MergeGit(directory: plan.target,
                    args: ["rev-list", "--count", "refs/heads/\(plan.targetBranch)..\(plan.sourceCommit)"]))
                guard remaining.trimmingCharacters(in: .newlines) == "0" else { throw MergeWorkflowError.notIntegrated }
                return .merged
            } catch {
                // Conflicts and commit-hook failures leave a resumable merge, rather than a failed workflow.
                let state = try await GitMergeState.read(using: session)
                if state.isMerging && state.incomingCommits.contains(plan.sourceCommit) {
                    return .inProgress(state, diagnostic: error.localizedDescription)
                }
                throw error
            }
        }
    }

    public static func removeSource(_ plan: WorktreeCompletionPlan) async throws {
        try await validateSource(plan)
        try await requireIntegrated(plan)
        let trees = try await GitRuntime.run(GitWorktreeList(directory: plan.target))
        guard let source = trees.first(where: { $0.id == plan.source }), !source.isMain, !source.isLocked else { throw MergeWorkflowError.cleanupBlocked }
        try await GitRuntime.run(GitWorktreeCommand(directory: plan.target, operation: .remove(plan.source)))
    }

    public static func deleteSourceBranch(_ plan: WorktreeCompletionPlan) async throws {
        try await requireIntegrated(plan)
        guard try await revision("refs/heads/\(plan.sourceBranch)", in: plan.target) == plan.sourceCommit else { throw MergeWorkflowError.changed }
        let trees = try await GitRuntime.run(GitWorktreeList(directory: plan.target))
        guard !trees.contains(where: { $0.branch == plan.sourceBranch }) else { throw MergeWorkflowError.cleanupBlocked }
        try await GitRuntime.run(GitBranchDelete(directory: plan.target, branchName: plan.sourceBranch))
    }

    public static func requireIntegrated(_ plan: WorktreeCompletionPlan) async throws {
        let count = try await GitRuntime.run(MergeGit(directory: plan.target,
            args: ["rev-list", "--count", "refs/heads/\(plan.targetBranch)..\(plan.sourceCommit)"]))
        guard count.trimmingCharacters(in: .newlines) == "0" else { throw MergeWorkflowError.notIntegrated }
        guard try await GitMergeState.read(in: plan.target).isMerging == false else { throw MergeWorkflowError.operationInProgress }
    }

    private static func validateSource(_ plan: WorktreeCompletionPlan) async throws {
        try await requireClean(plan.source)
        let branches = try await GitRuntime.run(GitBranch(directory: plan.source))
        guard branches.current?.name == plan.sourceBranch,
              try await revision("HEAD", in: plan.source) == plan.sourceCommit,
              try await revision("refs/heads/\(plan.sourceBranch)", in: plan.source) == plan.sourceCommit else { throw MergeWorkflowError.changed }
    }

    private static func revision(_ reference: String, in directory: URL) async throws -> String {
        try await GitRuntime.read(at: directory, readOnly: true) { try await revision(reference, using: $0) }
    }
    private static func revision(_ reference: String, using session: GitRuntime.Session) async throws -> String {
        try await session.run(MergeGit(directory: session.directory, args: ["rev-parse", "--verify", "--end-of-options", reference + "^{commit}"]))
            .trimmingCharacters(in: .newlines)
    }
    private static func requireClean(_ directory: URL) async throws {
        try await GitRuntime.read(at: directory, readOnly: true) { try await requireClean(using: $0) }
    }
    private static func requireClean(using session: GitRuntime.Session) async throws {
        for name in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply"] {
            let path = try await session.run(GitRevParse(directory: session.directory, gitPath: name))
            let url = URL(fileURLWithPath: path, relativeTo: session.directory.appendingPathComponent("", isDirectory: true))
            guard !FileManager.default.fileExists(atPath: url.path) else { throw MergeWorkflowError.operationInProgress }
        }
        let status = try await session.run(MergeGit(directory: session.directory, args: ["status", "--porcelain", "-z", "--untracked-files=all"]))
        guard status.isEmpty else {
            throw GitExecutionError(description: String(format: NSLocalizedString("Commit or stash changes in %@ before merging.", comment: ""), session.directory.path))
        }
    }
}

private struct MergeGit: RepositoryCommand {
    var directory: URL
    let args: [String]
    var arguments: [String] { ["git"] + args }
    func parse(for standardOutput: String) -> String { standardOutput }
}

public enum MergeWorkflowError: LocalizedError {
    case invalidConflicts, noMerge, conflictMarkers, unresolved, linkedBranchRequired, sameBranch
    case targetWorktreeRequired, changed, cleanupBlocked, notIntegrated, operationInProgress
    public var errorDescription: String? {
        switch self {
        case .invalidConflicts: NSLocalizedString("Git returned invalid merge information.", comment: "")
        case .noMerge: NSLocalizedString("There is no active merge for this file or worktree. Refresh and try again.", comment: "")
        case .conflictMarkers: NSLocalizedString("Remove the conflict markers before marking this file as resolved.", comment: "")
        case .unresolved: NSLocalizedString("Resolve all conflicts and stage your changes before continuing the merge.", comment: "")
        case .linkedBranchRequired: NSLocalizedString("Finish requires a linked worktree with a local branch.", comment: "")
        case .sameBranch: NSLocalizedString("Choose a different target branch.", comment: "")
        case .targetWorktreeRequired: NSLocalizedString("Open the target branch in another worktree before finishing.", comment: "")
        case .changed: NSLocalizedString("The branch or commit changed. Refresh the merge preview before continuing.", comment: "")
        case .cleanupBlocked: NSLocalizedString("The worktree is locked, missing, or its branch is still checked out. Keep it or unlock it before cleanup.", comment: "")
        case .notIntegrated: NSLocalizedString("The target branch does not contain all source commits. The worktree and branch were kept.", comment: "")
        case .operationInProgress: NSLocalizedString("Finish the existing merge, rebase, or cherry-pick before starting another merge.", comment: "")
        }
    }
}
