import FoldGitCore
import Foundation
import Observation

/// Window-local presentation state. Stale refreshes cannot overwrite a newer repository request.
@MainActor
@Observable final class RepositorySession {
    var history = HistoryStore()
    var remote = RemoteSyncState()
    private(set) var mergeState: GitMergeState?
    private(set) var branch: Branch?
    private(set) var error: (any Error)?
    private var generation = 0

    func refresh(in directory: URL, fetchRemote: Bool) async {
        generation += 1
        let request = generation
        do {
            // Only a detached HEAD needs the full listing, which names the detached commit.
            var branch = try await GitRuntime.run(GitCurrentBranch(directory: directory)).map { Branch(name: $0, isCurrent: true) }
            if branch == nil { branch = try await GitRuntime.run(GitBranch(directory: directory)).current }
            guard request == generation, !Task.isCancelled else { return }
            self.branch = branch
            let mergeState = try await GitMergeState.read(in: directory)
            guard request == generation, !Task.isCancelled else { return }
            self.mergeState = mergeState
            history.directory = directory
            remote.folderURL = directory
            remote.branch = branch
            // Show cached local history immediately, then incorporate any fetched ref updates.
            await history.refresh()
            guard request == generation, !Task.isCancelled else { return }
            await remote.sync(fetchRemote: fetchRemote)
            guard request == generation, !Task.isCancelled else { return }
            if fetchRemote { await history.refresh() }
            guard request == generation, !Task.isCancelled else { return }
            error = history.error
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            self.error = error
        }
    }
}
