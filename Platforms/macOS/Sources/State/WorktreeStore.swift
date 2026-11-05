import FoldGitCore
import Foundation
import Observation

@MainActor
@Observable final class WorktreeStore {
    private(set) var families: [URL: [GitWorktree]] = [:]
    private(set) var errors: [URL: String] = [:]
    /// Status lives beside the worktree list, so every view that has the list can read it.
    let statuses = WorktreeStatusStore()

    func list(for url: URL) -> [GitWorktree] { families[key(url)] ?? [] }
    func worktree(at url: URL) -> GitWorktree? { list(for: url).first { $0.id == key(url) } }
    func contains(_ url: URL) -> Bool { worktree(at: url) != nil }

    func sidebarBranch(for url: URL, showInformation: Bool, showRepositoryBranch: Bool) -> String? {
        guard showInformation ? list(for: url).count > 1 : showRepositoryBranch,
              let tree = worktree(at: url), !tree.isBare else { return nil }
        return tree.branch ?? String(localized: "Detached HEAD")
    }

    func repositoryIdentity(for url: URL) -> URL { list(for: url).first?.id ?? key(url) }

    func showsInformation(for url: URL?, global: Bool, preferences: RepositoryWorktreePreferences) -> Bool {
        guard let url else { return false }
        return preferences.isEnabled(for: repositoryIdentity(for: url), global: global)
    }

    func visibility(for url: URL?, showInformation: Bool, currentBranch: String? = nil) -> WorktreeVisibility {
        guard let url else { return WorktreeVisibility(showInformation: showInformation) }
        return WorktreeVisibility(showInformation: showInformation,
            linkedBranches: Set(list(for: url).filter { !$0.isMain && !$0.isBare }.compactMap(\.branch)),
            currentBranch: currentBranch ?? worktree(at: url)?.branch)
    }

    /// Explicit sidebar entries keep their groups. Only one anchor displays unsaved related directories.
    func sidebarChildren(for url: URL, saved: [WorkspaceEntry]) -> [GitWorktree] {
        let trees = list(for: url)
        let ids = Set(trees.map(\.id))
        let mainID = trees.first(where: \.isMain)?.id
        let anchor = saved.first { $0.identity == mainID } ?? saved.first { ids.contains($0.identity) }
        guard anchor?.identity == key(url) else { return [] }
        let savedIDs = Set(saved.map(\.identity))
        return trees.filter { !$0.isBare && $0.id != key(url) && !savedIDs.contains($0.id) }
    }

    func replacementAnchor(removing url: URL, saved: [WorkspaceEntry], family: URL) -> URL? {
        guard saved.contains(where: { $0.identity == key(url) }) else { return nil }
        let remaining = list(for: family).filter { !$0.isBare && !$0.isPrunable }
        let remainingIDs = Set(remaining.map(\.id))
        guard !saved.contains(where: { $0.identity != key(url) && remainingIDs.contains($0.identity) }) else { return nil }
        return remaining.first?.url
    }

    func destination(for branch: String, in directory: URL) -> GitWorktree? {
        list(for: directory).first { $0.branch == branch && $0.id != key(directory) }
    }

    func source(for url: URL) -> URL {
        let trees = list(for: url)
        return trees.first { !$0.isPrunable && FileManager.default.fileExists(atPath: $0.url.path) }?.url ?? url
    }

    func refresh(_ url: URL) async throws {
        let trees = try await GitRuntime.run(GitWorktreeList(directory: source(for: url)))
        // Polling repeats this every few seconds; unchanged results must not invalidate the sidebar.
        var updatedFamilies = families
        var updatedErrors = errors
        for identity in list(for: url).map(\.id) { updatedFamilies[identity] = nil; updatedErrors[identity] = nil }
        for tree in trees { updatedFamilies[tree.id] = trees }
        updatedFamilies[key(url)] = trees
        updatedErrors[key(url)] = nil
        if updatedFamilies != families { families = updatedFamilies }
        if updatedErrors != errors { errors = updatedErrors }
    }

    func refreshRepositories(_ urls: [URL]) async {
        var visited: Set<URL> = []
        for url in urls {
            guard !Task.isCancelled else { return }
            guard !visited.contains(key(url)) else { continue }
            do {
                try await refresh(url)
                visited.formUnion(list(for: url).map(\.id))
            } catch {
                guard !Task.isCancelled else { return }
                if errors[key(url)] != error.localizedDescription { errors[key(url)] = error.localizedDescription }
            }
        }
    }

    func execute(_ operation: WorktreeOperation, in directory: URL) async throws {
        let source = source(for: directory)
        try await GitRuntime.run(GitWorktreeCommand(directory: source, operation: operation))
        try await refresh(source)
    }

    /// Branch subtitles need HEAD changes, without scanning working files or loading status counts.
    func monitorBranches(_ families: [[GitWorktree]], minimumInterval: Duration = .seconds(2)) async {
        guard let statusPlan = try? await RepositoryChangeMonitor.statusWatchPlan(for: families), !Task.isCancelled else { return }
        let plan = RepositoryChangeMonitor.StatusWatchPlan(roots: statusPlan.roots.filter { $0.kind != .files },
                                                          families: statusPlan.families)
        let feed = RepositoryChangeMonitor.statusChanges(in: plan)
        await refreshRepositories(families.compactMap { $0.first?.url })
        for await _ in feed.ticks {
            try? await Task.sleep(for: minimumInterval)
            guard !Task.isCancelled else { return }
            await refreshRepositories(feed.take().listPaths.map { URL(fileURLWithPath: $0) })
        }
    }

    /// Keeps the statuses of `families` current until cancelled: one full read, then reads limited to the worktrees
    /// that file events or app mutations touched. During builds or installs events never stop, so reads start at
    /// most once per `minimumInterval` and each one covers everything that changed while the previous one ran.
    func monitorStatuses(_ families: [[GitWorktree]], minimumInterval: Duration = .seconds(2)) async {
        guard let plan = try? await RepositoryChangeMonitor.statusWatchPlan(for: families), !Task.isCancelled else { return }
        let feed = RepositoryChangeMonitor.statusChanges(in: plan)
        await statuses.refresh(families)
        let clock = ContinuousClock()
        var last = clock.now
        for await _ in feed.ticks {
            do { try await clock.sleep(until: last.advanced(by: minimumInterval)) } catch { return }
            let change = feed.take()
            guard !change.isEmpty else { continue }
            last = clock.now
            await refreshAffected(change)
        }
    }

    func refreshAffected(_ change: RepositoryChangeMonitor.StatusChange) async {
        var visited: Set<URL> = []
        for path in change.paths.union(change.listPaths) {
            let url = URL(fileURLWithPath: path)
            let family = list(for: url)
            guard let anchor = family.first(where: { !$0.isBare && !$0.isPrunable && FileManager.default.fileExists(atPath: $0.url.path) }),
                  visited.insert(anchor.id).inserted else { continue }
            // Plain edits and staging leave the worktree list as it is; only HEAD and worktree changes reload it.
            if family.contains(where: { change.listPaths.contains($0.id.path) }) {
                do {
                    try await refresh(anchor.url)
                } catch {
                    guard !Task.isCancelled else { return }
                    errors[anchor.id] = error.localizedDescription
                    continue
                }
            }
            await statuses.refresh([list(for: anchor.url)], onlyPaths: change.paths)
        }
    }

    private func key(_ url: URL) -> URL { RepositoryLocation.canonical(url) }
}

/// Display filtering never changes repository data or branch occupancy checks.
struct WorktreeVisibility: Equatable {
    var showInformation = true
    var linkedBranches: Set<String> = []
    var currentBranch: String?

    func showsBranch(_ name: String) -> Bool {
        guard !showInformation, !name.hasPrefix("HEAD -> ") else { return true }
        let branch = name.hasPrefix("refs/heads/") ? String(name.dropFirst(11)) : name
        return branch == currentBranch || !linkedBranches.contains(branch)
    }

    func branches(_ branches: [Branch]) -> [Branch] {
        branches.filter { $0.isCurrent || showsBranch($0.name) }
    }

    func decorations(_ names: [String]) -> [String] { names.filter(showsBranch) }
}
