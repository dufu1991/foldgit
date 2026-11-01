import FoldGitCore
import Foundation
import Observation

/// Working tree and trunk status for each worktree shown in the sidebar.
/// Reads take no optional locks and run a few at a time, so tools working inside the worktrees are never blocked.
@MainActor
@Observable final class WorktreeStatusStore {
    private(set) var statuses: [URL: WorktreeStatus] = [:]
    private(set) var trunks: [URL: TrunkReference] = [:]
    @ObservationIgnored private let cache = TrunkComparisonCache()
    static let concurrentReads = 4

    func status(for url: URL) -> WorktreeStatus? { statuses[RepositoryLocation.canonical(url)] }

    /// True when the worktree has the trunk branch checked out, where divergence from the trunk means nothing.
    func isOnTrunk(_ url: URL) -> Bool {
        let key = RepositoryLocation.canonical(url)
        guard let branch = statuses[key]?.working.branch, let local = trunks[key]?.local else { return false }
        return local == "refs/heads/" + branch
    }

    /// Refreshes every worktree of the given families. Pass `onlyPaths` (canonical worktree paths) to limit reads
    /// to worktrees with file events, reusing the trunk already resolved for their family.
    func refresh(_ families: [[GitWorktree]], onlyPaths: Set<String>? = nil) async {
        var jobs: [(GitWorktree, TrunkReference?)] = []
        for trees in families {
            let usable = trees.filter { !$0.isBare && !$0.isPrunable && FileManager.default.fileExists(atPath: $0.url.path) }
            let targets = onlyPaths.map { paths in usable.filter { paths.contains($0.id.path) } } ?? usable
            guard let anchor = usable.first, !targets.isEmpty else { continue }
            var trunk = onlyPaths == nil ? nil : trunks[anchor.id]
            if trunk == nil {
                trunk = try? await TrunkReference.resolve(in: anchor.url, mainWorktreeBranch: trees.first(where: \.isMain)?.branch)
            }
            for tree in usable where trunks[tree.id] != trunk { trunks[tree.id] = trunk }
            jobs += targets.map { ($0, trunk) }
        }
        let cache = cache
        var updated = statuses
        var start = jobs.startIndex
        while start < jobs.endIndex {
            guard !Task.isCancelled else { return }
            let batch = jobs[start..<min(start + Self.concurrentReads, jobs.endIndex)]
            start = batch.endIndex
            let results = await withTaskGroup(of: (URL, WorktreeStatus?).self) { group in
                for (tree, trunk) in batch {
                    group.addTask { (tree.id, try? await WorktreeStatus.read(tree.url, trunk: trunk, cache: cache)) }
                }
                var results: [(URL, WorktreeStatus?)] = []
                for await result in group { results.append(result) }
                return results
            }
            for (id, status) in results { updated[id] = status }
        }
        // Polling repeats this every few seconds; unchanged results must not invalidate the sidebar.
        if updated != statuses { statuses = updated }
    }
}
