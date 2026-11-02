import FoldGitCore
import Foundation
import Observation

@MainActor
@Observable final class WorktreeCleanupModel {
    enum Phase { case loading, review, running, finished }
    enum Outcome: Equatable {
        case removed(WorktreeBranchOutcome)
        case failed(String)
    }

    let repository: URL
    private(set) var candidates: [WorktreeCleanupCandidate] = []
    private(set) var outcomes: [URL: Outcome] = [:]
    private(set) var phase = Phase.loading
    var selection: Set<URL> = []
    var deleteBranches = true
    var errorMessage: String?

    init(repository: URL) { self.repository = repository }

    var selectedCount: Int { candidates.filter { selection.contains($0.id) }.count }

    func load() async {
        phase = .loading
        errorMessage = nil
        outcomes = [:]
        do {
            candidates = try await WorktreeCleanup.candidates(in: repository)
            let now = Date.now
            selection = Set(candidates.filter { $0.isSelectedByDefault(at: now) }.map(\.id))
        } catch {
            candidates = []
            errorMessage = OperationFailure("Load Worktrees", error, directory: repository).localizedDescription
        }
        phase = .review
    }

    /// Removes the selected worktrees one at a time. A worktree that changed since the preview is kept and reported.
    func run(onRemoved: (URL) async -> Void) async {
        guard phase == .review else { return }
        phase = .running
        errorMessage = nil
        for candidate in candidates where selection.contains(candidate.id) {
            do {
                outcomes[candidate.id] = .removed(try await WorktreeCleanup.remove(candidate, deletingBranch: deleteBranches))
                await onRemoved(candidate.tree.url)
            } catch {
                outcomes[candidate.id] = .failed(error.localizedDescription)
            }
        }
        phase = .finished
    }
}
