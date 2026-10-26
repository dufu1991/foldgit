import FoldGitCore
import Foundation
import Observation

@MainActor
@Observable final class HistoryStore {
    var number = 100
    var directory: URL? {
        didSet {
            if oldValue != directory { cancelSearch(); invalidateSearchIndex() }
        }
    }
    private(set) var searchText = ""
    private(set) var isSearching = false
    @ObservationIgnored private(set) var searchTask: Task<Void, Never>?
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

    func refresh() async { invalidateSearchIndex(); await reload(limit: number) }
    func update() async { invalidateSearchIndex(); await reload(limit: max(number, commits.count)) }

    private func invalidateSearchIndex() { searchIndex = nil; matchingHashes = []; generation += 1 }

    private func searchResults(in directory: URL, text: String, request: Int) async throws -> [String] {
        let index: CommitSearchIndex
        if let searchIndex { index = searchIndex }
        else {
            index = try await GitRuntime.run(GitCommitSearchIndex(directory: directory))
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
        defer { if request == generation { isSearching = false } }
        do {
            let previousChanges = notCommitted
            // Reading the working tree overlaps with the history queries below.
            async let snapshot = includeWorkingTree ? WorktreeSnapshot.read(in: directory).changes : previousChanges
            let history: [Commit]
            let count: Int?
            let hashes: [String]
            if text.isEmpty {
                hashes = []
                // Both commands only read, so the queue runs them at the same time.
                async let page = GitRuntime.run(GitLog(directory: directory, number: limit))
                async let total = GitRuntime.run(GitRevListCount(directory: directory))
                (history, count) = try await (page, total)
            } else {
                hashes = try await searchResults(in: directory, text: text, request: request)
                try Task.checkCancellation()
                guard request == generation else { return }
                history = hashes.isEmpty ? [] : try await GitRuntime.run(GitCommitSearchPage(directory: directory, hashes: Array(hashes.prefix(limit))))
                count = hashes.count
            }
            let changes = try await snapshot
            guard request == generation, !Task.isCancelled else { return }
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
        guard let directory, canLoadMore, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        let request = generation
        do {
            let additional: [Commit]
            if searchText.isEmpty {
                additional = try await GitRuntime.run(GitLog(directory: directory, number: number, skip: commits.count))
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
