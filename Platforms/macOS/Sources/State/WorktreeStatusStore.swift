import FoldGitCore
import Foundation
import Observation

/// One worktree's status. Each row observes only its own entry, so a change in one worktree redraws one row.
@MainActor
@Observable final class WorktreeStatusEntry {
    fileprivate(set) var status: WorktreeStatus?
    fileprivate(set) var trunk: TrunkReference?
    fileprivate(set) var failed = false

    /// True when the worktree has the trunk branch checked out, where divergence from the trunk means nothing.
    var isOnTrunk: Bool {
        guard let branch = status?.working.branch, let local = trunk?.local else { return false }
        return local == "refs/heads/" + branch
    }

    /// Observation does not compare values, so only real changes are written.
    fileprivate func apply(status: WorktreeStatus?, trunk: TrunkReference?) {
        if self.status != status { self.status = status }
        if self.trunk != trunk { self.trunk = trunk }
        if failed != (status == nil) { failed = status == nil }
    }
}

/// Working tree and trunk status for each worktree shown in the sidebar.
/// Reads take no optional locks and run a few at a time, so tools working inside the worktrees are never blocked.
@MainActor
final class WorktreeStatusStore {
    private var entries: [URL: WorktreeStatusEntry] = [:]
    private let cache = TrunkComparisonCache()
    /// The poll, file events and the management sheet refresh concurrently. Each refresh takes a newer generation,
    /// and a result is applied only if no newer refresh has already written that worktree.
    private var generation = 0
    private var appliedGeneration: [URL: Int] = [:]
    static let concurrentReads = 4

    /// Entries are created on first read, so a view can observe a worktree before its first status arrives.
    func entry(for url: URL) -> WorktreeStatusEntry {
        let key = RepositoryLocation.canonical(url)
        if let entry = entries[key] { return entry }
        let entry = WorktreeStatusEntry()
        entries[key] = entry
        return entry
    }

    func status(for url: URL) -> WorktreeStatus? { entry(for: url).status }
    func hasFailed(_ url: URL) -> Bool { entry(for: url).failed }
    func isOnTrunk(_ url: URL) -> Bool { entry(for: url).isOnTrunk }

    /// Refreshes every worktree of the given families. Pass `onlyPaths` (canonical worktree paths) to limit reads
    /// to affected worktrees. Resolve the trunk again so ref and upstream changes are reflected.
    func refresh(_ families: [[GitWorktree]], onlyPaths: Set<String>? = nil) async {
        generation += 1
        let token = generation
        var jobs: [(GitWorktree, TrunkReference?)] = []
        for trees in families {
            let usable = trees.filter { !$0.isBare && !$0.isPrunable && FileManager.default.fileExists(atPath: $0.url.path) }
            let targets = onlyPaths.map { paths in usable.filter { paths.contains($0.id.path) } } ?? usable
            guard let anchor = usable.first, !targets.isEmpty else { continue }
            let trunk = try? await TrunkReference.resolve(in: anchor.url, mainWorktreeBranch: trees.first(where: \.isMain)?.branch)
            jobs += targets.map { ($0, trunk) }
        }
        let cache = cache
        var start = jobs.startIndex
        while start < jobs.endIndex {
            guard !Task.isCancelled else { return }
            let batch = jobs[start..<min(start + Self.concurrentReads, jobs.endIndex)]
            start = batch.endIndex
            let results = await withTaskGroup(of: (URL, WorktreeStatus?, TrunkReference?).self) { group in
                for (tree, trunk) in batch {
                    group.addTask { (tree.id, try? await WorktreeStatus.read(tree.url, trunk: trunk, cache: cache), trunk) }
                }
                var results: [(URL, WorktreeStatus?, TrunkReference?)] = []
                for await result in group { results.append(result) }
                return results
            }
            // Concurrent refreshes keep each other's results; a newer one that already wrote a worktree wins.
            for (id, status, trunk) in results where appliedGeneration[id, default: 0] <= token {
                appliedGeneration[id] = token
                entry(for: id).apply(status: status, trunk: trunk)
            }
        }
        if onlyPaths == nil { pruneRemovedWorktrees() }
    }

    /// Other windows may show other repositories, so only worktrees that no longer exist on disk are forgotten.
    private func pruneRemovedWorktrees() {
        for (id, entry) in entries where !FileManager.default.fileExists(atPath: id.path) {
            appliedGeneration[id] = nil
            entry.apply(status: nil, trunk: nil)
            entry.failed = false
        }
    }
}
