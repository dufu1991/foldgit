import FoldGitCore
import Foundation
import Observation

@MainActor
@Observable final class RemoteSyncState {
    var folderURL: URL?
    var branch: Branch?
    private(set) var tracking: TrackingBranch?
    var shouldPull = false
    var shouldPush = false
    var syncError: String?
    private var generation = 0

    func sync(fetchRemote: Bool = true) async {
        generation += 1
        let request = generation
        guard let folderURL, let branch, !branch.isDetached else {
            tracking = nil
            shouldPull = false
            shouldPush = false
            return
        }
        do {
            if fetchRemote { try await RemoteUpdateService.shared.execute(GitFetch(directory: folderURL)) }
            let tracking = try await TrackingBranch.inspect(in: folderURL, branch: branch.name)
            guard request == generation, !Task.isCancelled else { return }
            self.tracking = tracking
            syncError = nil
            shouldPull = (tracking?.behind ?? 0) > 0
            shouldPush = tracking.map { $0.upstream == nil || $0.ahead > 0 } ?? false
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            tracking = nil
            syncError = error.localizedDescription
            shouldPull = false
            shouldPush = false
        }
    }
}
