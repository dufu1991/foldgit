import FoldGitCore
import Foundation
import Observation

@MainActor
@Observable final class HistoryStore {
    struct ScrollRequest: Equatable {
        let id = UUID()
        let target: String
    }

    private let defaults: UserDefaults
    private(set) var scope = HistoryScope.currentBranch
    private(set) var snapshot: HistorySnapshot?
    private(set) var scrollRequest: ScrollRequest?
    private(set) var isRevealingIncoming = false
    var number = 100

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private var preferencePath: String? { directory.map(RepositoryLocation.key(for:)) }

    private func savedScope() -> HistoryScope {
        guard let preferencePath,
              let values = defaults.dictionary(forKey: PreferenceKey.repositoryHistoryScopes.rawValue) as? [String: String],
              let value = values[preferencePath], let scope = HistoryScope(rawValue: value) else { return .currentBranch }
        return scope
    }

    private func saveScope() {
        guard let preferencePath else { return }
        var values = defaults.dictionary(forKey: PreferenceKey.repositoryHistoryScopes.rawValue) as? [String: String] ?? [:]
        values[preferencePath] = scope.rawValue
        defaults.set(values, forKey: PreferenceKey.repositoryHistoryScopes.rawValue)
    }

    func setScope(_ scope: HistoryScope) async {
        guard self.scope != scope else { return }
        cancelSearch()
        self.scope = scope
        saveScope()
        invalidateSearchIndex()
        await reload(limit: number)
    }

    func isOutsideCurrentBranch(_ hash: String) -> Bool { snapshot?.outsideCurrentBranch.contains(hash) == true }
    func isIncoming(_ hash: String) -> Bool { snapshot?.incomingHashes.contains(hash) == true }
    func isOutgoing(_ hash: String) -> Bool { snapshot?.outgoing.contains(hash) == true }

    /// Load through the target even when unrelated branches fill the first page.
    func revealIncoming() async -> String? {
        guard !isRevealingIncoming else { return nil }
        isRevealingIncoming = true
        defer { isRevealingIncoming = false }
        cancelSearch()
        scope = .allCommits
        saveScope()
        searchText = ""
        invalidateSearchIndex()
        var request = generation + 1
        await reload(limit: number)
        guard request == generation, error == nil, let snapshot, let directory,
              let target = snapshot.incoming.first else { return nil }
        if !commits.contains(where: { $0.id == target }) {
            do {
                let hashes = try await GitRuntime.run(GitRevisionHashes(directory: directory, revisions: snapshot.revisions(for: .allCommits)))
                guard request == generation, let index = hashes.firstIndex(of: target) else { return nil }
                request += 1
                await reload(limit: max(number, index + 1))
            } catch {
                if request == generation { self.error = error }
                return nil
            }
        }
        guard request == generation, commits.contains(where: { $0.id == target }) else { return nil }
        scrollRequest = ScrollRequest(target: target)
        return target
    }
    var directory: URL? {
        didSet {
            if oldValue != directory {
                cancelSearch()
                invalidateSearchIndex()
                snapshot = nil
                scope = savedScope()
                commits = []
                notCommitted = nil
                totalCommitsCount = nil
                error = nil
            }
        }
    }
    private(set) var searchText = ""
    private(set) var isSearching = false
    @ObservationIgnored private(set) var searchTask: Task<Void, Never>?
    private var snapshotIsStale = true
    private var reloadRequest: Int?
    private var searchIndex: CommitSearchIndex?
    private var matchingHashes: [String] = []
    var commits: [Commit] = []
    var notCommitted: NotCommitted?
    var totalCommitsCount: Int?
    var error: (any Error)?
    private var generation = 0
    private var loadingMore = false
    var canLoadMore: Bool { !isSearching && (totalCommitsCount.map { $0 > commits.count } ?? false) }

    func logs() -> [Log] {
        let history = commits.map(Log.committed)
        guard searchText.isEmpty else { return history }
        return notCommitted.map { $0.isEmpty ? history : [.notCommitted] + history } ?? history
    }

    /// Composition events cancel pending work but never submit the marked text.
    func search(_ text: String, isComposing: Bool = false) {
        cancelSearch()
        guard !isComposing else { return }
        searchText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        isSearching = true
        searchTask = Task {
            do {
                if !searchText.isEmpty { try await Task.sleep(for: .milliseconds(300)) }
                try Task.checkCancellation()
                await reload(limit: number, includeWorkingTree: false)
            } catch is CancellationError {
                // A newer input owns the loading state and the result.
            } catch { self.error = error }
        }
    }

    func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        generation += 1
        isSearching = false
    }

    func refresh() async { invalidateSearchIndex(); await reload(limit: max(number, commits.count)) }
    func update() async { invalidateSearchIndex(); await reload(limit: max(number, commits.count)) }

    private func invalidateSearchIndex() { searchIndex = nil; snapshotIsStale = true; matchingHashes = []; generation += 1 }

    private func searchResults(in directory: URL, revisions: [String], text: String, request: Int) async throws -> [String] {
        let index: CommitSearchIndex
        if let searchIndex { index = searchIndex }
        else {
            index = try await GitRuntime.run(GitCommitSearchIndex(directory: directory, revisions: revisions))
            guard request == generation else { throw CancellationError() }
            searchIndex = index
        }
        let matching = Task.detached(priority: .userInitiated) { try index.hashes(matching: text) }
        return try await withTaskCancellationHandler { try await matching.value } onCancel: { matching.cancel() }
    }

    private func reload(limit: Int, includeWorkingTree: Bool = true) async {
        generation += 1
        let request = generation
        guard let directory else { removeAll(); return }
        let text = searchText
        reloadRequest = request
        defer {
            if reloadRequest == request { reloadRequest = nil }
            if request == generation { isSearching = false }
        }
        do {
            let currentSnapshot: HistorySnapshot
            if let snapshot, !snapshotIsStale { currentSnapshot = snapshot }
            else { currentSnapshot = try await HistorySnapshot.read(in: directory) }
            guard request == generation, !Task.isCancelled else { return }
            let revisions = currentSnapshot.revisions(for: scope)
            let previousChanges = notCommitted
            // Reading the working tree overlaps with the history queries below.
            async let changesSnapshot = includeWorkingTree ? WorktreeSnapshot.read(in: directory).changes : previousChanges
            let history: [Commit]
            let count: Int?
            let hashes: [String]
            if revisions.isEmpty {
                history = []
                hashes = []
                count = 0
            } else if text.isEmpty {
                hashes = []
                // Both commands only read, so the queue runs them at the same time.
                async let page = GitRuntime.run(GitLog(directory: directory, number: limit, revisionRange: revisions))
                async let total = GitRuntime.run(GitRevListCount(directory: directory, revisions: revisions))
                (history, count) = try await (page, total)
            } else {
                hashes = try await searchResults(in: directory, revisions: revisions, text: text, request: request)
                try Task.checkCancellation()
                guard request == generation else { return }
                history = hashes.isEmpty ? [] : try await GitRuntime.run(GitCommitSearchPage(directory: directory, hashes: Array(hashes.prefix(limit))))
                count = hashes.count
            }
            let changes = try await changesSnapshot
            guard request == generation, !Task.isCancelled else { return }
            snapshot = currentSnapshot
            snapshotIsStale = false
            notCommitted = changes
            commits = history
            matchingHashes = hashes
            totalCommitsCount = count
            error = nil
        } catch {
            guard request == generation, !Task.isCancelled, !(error is CancellationError) else { return }
            self.error = error
        }
    }

    func removeAll() {
        cancelSearch()
        invalidateSearchIndex()
        commits = []
        notCommitted = nil
        totalCommitsCount = nil
        error = nil
    }

    func logViewTask(_ log: Log) async {
        if case .committed(let commit) = log, commit == commits.last { await loadMore() }
    }

    func loadMore() async {
        guard let directory, canLoadMore, !loadingMore, reloadRequest == nil else { return }
        loadingMore = true
        defer { loadingMore = false }
        let request = generation
        do {
            let additional: [Commit]
            if searchText.isEmpty {
                guard let snapshot else { return }
                additional = try await GitRuntime.run(GitLog(directory: directory, number: number, skip: commits.count,
                                                            revisionRange: snapshot.revisions(for: scope)))
            } else {
                let page = Array(matchingHashes.dropFirst(commits.count).prefix(number))
                guard !page.isEmpty else { return }
                additional = try await GitRuntime.run(GitCommitSearchPage(directory: directory, hashes: page))
            }
            guard request == generation, !Task.isCancelled else { return }
            let existing = Set(commits.map(\.id))
            commits.append(contentsOf: additional.filter { !existing.contains($0.id) })
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            self.error = error
        }
    }

    func nextLogID(logID: String) -> String? {
        if logID == Log.notCommitted.id { return commits.first?.id }
        guard let index = commits.firstIndex(where: { $0.id == logID }), index + 1 < commits.count else { return nil }
        return commits[index + 1].id
    }

    func previousLogID(logID: String) -> String? {
        guard logID != Log.notCommitted.id, let index = commits.firstIndex(where: { $0.id == logID }) else { return nil }
        if index == 0 { return searchText.isEmpty && notCommitted?.isEmpty == false ? Log.notCommitted.id : nil }
        return commits[index - 1].id
    }
}
