import FoldGitCore
import Foundation
import Observation

@MainActor
@Observable final class WorktreeCompletionModel {
    enum Phase { case review, conflicts, merged, done }
    let source: URL
    var targets: [Branch] = []
    var targetBranch = ""
    private(set) var plan: WorktreeCompletionPlan?
    private(set) var phase = Phase.review
    private(set) var isBusy = false
    private(set) var sourceRemoved = false
    private(set) var branchDeleted = false
    var removeWorktree = true
    var deleteBranch = false
    var errorMessage: String?

    init(source: URL) { self.source = source }

    func load() async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let branches = try await GitRuntime.run(GitBranch(directory: source))
            let current = branches.current?.name
            let available = branches.filter { !$0.isDetached && $0.name != current }
            if !available.contains(where: { $0.name == targetBranch }) {
                let trees = try await GitRuntime.run(GitWorktreeList(directory: source))
                let primary = trees.first(where: \.isMain)?.branch
                targetBranch = ["main", "master", primary].compactMap { $0 }.first { name in available.contains { $0.name == name } }
                    ?? available.first?.name ?? ""
            }
            targets = available
            try await prepare()
        } catch { errorMessage = error.localizedDescription }
    }

    func preview() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        plan = nil
        phase = .review
        defer { isBusy = false }
        do { try await prepare() } catch { errorMessage = error.localizedDescription }
    }

    private func prepare() async throws {
        guard !targetBranch.isEmpty else { return }
        let prepared = try await WorktreeCompletion.prepare(source: source, targetBranch: targetBranch)
        plan = prepared
        let state = try await GitMergeState.read(in: prepared.target)
        phase = state.isMerging ? .conflicts : prepared.commitCount == 0 && !prepared.switchesTargetBranch ? .merged : .review
    }

    func merge() async {
        guard !isBusy, let plan, phase == .review, plan.targetBranch == targetBranch else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            switch try await WorktreeCompletion.merge(plan) {
            case .merged: phase = .merged
            case let .inProgress(state, diagnostic):
                phase = .conflicts
                errorMessage = state.conflicts.isEmpty ? diagnostic : nil
            }
            NotificationCenter.default.post(name: .repositoryMergeDidChange, object: plan.target)
        } catch { errorMessage = error.localizedDescription }
    }

    func mergeFinished() async {
        guard let plan else { return }
        do {
            try await WorktreeCompletion.requireIntegrated(plan)
            errorMessage = nil
            phase = .merged
        } catch {
            phase = .review
            self.plan = nil
            await preview()
        }
    }

    func mergeAborted() async {
        phase = .review
        plan = nil
        await preview()
    }

    func cleanup() async {
        guard !isBusy, let plan, phase == .merged else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await WorktreeCompletion.requireIntegrated(plan)
            if removeWorktree && !sourceRemoved {
                try await WorktreeCompletion.removeSource(plan)
                sourceRemoved = true
            }
            if deleteBranch && sourceRemoved && !branchDeleted {
                try await WorktreeCompletion.deleteSourceBranch(plan)
                branchDeleted = true
            }
            phase = .done
            NotificationCenter.default.post(name: .repositoryMergeDidChange, object: plan.target)
        } catch { errorMessage = error.localizedDescription }
    }
}

@MainActor
@Observable final class MergeResolutionModel {
    let directory: URL
    private(set) var state: GitMergeState?
    private(set) var isBusy = false
    var errorMessage: String?

    init(directory: URL) { self.directory = directory }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do { state = try await GitMergeState.read(in: directory) }
        catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    func resolve(_ path: String, choosing resolution: MergeResolution) async -> Bool {
        await perform { try await GitMergeWorkflow.resolve(path, choosing: resolution, in: self.directory) }
    }
    @discardableResult
    func continueMerge() async -> Bool {
        await perform { try await GitMergeWorkflow.continueMerge(in: self.directory) }
    }
    @discardableResult
    func abort() async -> Bool {
        await perform { try await GitMergeWorkflow.abort(in: self.directory) }
    }
    private func perform(_ operation: () async throws -> Void) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await operation()
            state = try await GitMergeState.read(in: directory)
            NotificationCenter.default.post(name: .repositoryMergeDidChange, object: directory)
            return true
        } catch {
            errorMessage = error.localizedDescription
            state = try? await GitMergeState.read(in: directory)
            return false
        }
    }
}
