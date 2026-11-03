import FoldGitCore
import Foundation
import Observation

enum RepositoryBrowseMode: String, CaseIterable {
    case commits, files
}

enum RepositoryFileDetailMode: String {
    case history, content
}

/// Window-local, demand-loaded state. File content changes do not invalidate committed history.
@MainActor
@Observable final class FileHistoryStore {
    private(set) var detailMode = RepositoryFileDetailMode.history
    let content = FileContentStore()
    private(set) var directory: URL?
    private(set) var isActive = false
    private(set) var selectedPath: String?
    private(set) var revealRequest: UUID?
    private(set) var selectedEntry: FileHistoryEntry?
    private(set) var entries: [FileHistoryEntry] = []
    private(set) var rows: [ChangeFileTree.Row] = []
    private(set) var fileCount = 0
    private(set) var collapsedDirectories: Set<String> = []
    private(set) var searchText = ""
    private(set) var canLoadMore = false
    private(set) var isLoadingFiles = false
    private(set) var isLoadingHistory = false
    private(set) var isLoadingDiff = false
    private(set) var diff: Diff?
    var error: (any Error)?
    let pageSize: Int
    typealias HistoryReader = @Sendable (URL, String, String, Int) async throws -> [FileHistoryEntry]
    typealias DiffReader = @Sendable (URL, FileHistoryEntry) async throws -> Diff
    @ObservationIgnored private let readHistory: HistoryReader
    @ObservationIgnored private let readDiff: DiffReader

    @ObservationIgnored private(set) var refreshTask: Task<Void, Never>?
    @ObservationIgnored private(set) var historyTask: Task<Void, Never>?
    @ObservationIgnored private(set) var diffTask: Task<Void, Never>?
    @ObservationIgnored private(set) var treeTask: Task<Void, Never>?
    private var paths: [String] = []
    private var tree = ChangeFileTree()
    private var head: String?
    private var hasSnapshot = false
    private var hasHistory = false
    private var historyGeneration = 0
    private var diffGeneration = 0
    private var refreshGeneration = 0
    private var treeGeneration = 0
    private var searchCollapsedDirectories: Set<String> = []
    private var pendingRevealPath: String?

    private struct Page {
        let entries: [FileHistoryEntry]
        let canLoadMore: Bool
        let textBytes: Int
    }
    // Cache only small histories; the currently displayed history can grow through explicit pagination.
    @ObservationIgnored private var histories: [String: Page] = [:]
    @ObservationIgnored private var recentPaths: [String] = []
    @ObservationIgnored private var diffs: [FileHistoryEntry: Diff] = [:]
    @ObservationIgnored private var recentDiffs: [FileHistoryEntry] = []

    init(pageSize: Int = 50,
         readHistory: @escaping HistoryReader = { directory, path, revision, limit in
             try await GitRuntime.run(GitFileHistory(directory: directory, path: path, revision: revision, limit: limit))
         },
         readDiff: @escaping DiffReader = { directory, entry in
             try await GitRuntime.run(GitFileHistoryDiff(directory: directory, entry: entry))
         }) {
        precondition(pageSize > 0)
        self.pageSize = pageSize
        self.readHistory = readHistory
        self.readDiff = readDiff
    }

    func activate(in directory: URL) {
        if self.directory != directory {
            suspendQueries()
            detailMode = .history
            self.directory = directory
            selectedPath = nil
            revealRequest = nil
            selectedEntry = nil
            entries = []
            diff = nil
            paths = []
            rows = []
            tree = ChangeFileTree()
            fileCount = 0
            collapsedDirectories = []
            searchText = ""
            searchCollapsedDirectories = []
            pendingRevealPath = nil
            head = nil
            hasSnapshot = false
            hasHistory = false
            histories = [:]
            recentPaths = []
            diffs = [:]
            recentDiffs = []
            error = nil
        }
        isActive = true
        refresh()
    }

    func deactivate() {
        isActive = false
        suspendQueries()
    }

    /// Called before repository writes too, so long-running readers can release the command queue.
    func suspendQueries() {
        content.hide()
        refreshGeneration += 1
        historyGeneration += 1
        diffGeneration += 1
        treeGeneration += 1
        refreshTask?.cancel()
        historyTask?.cancel()
        diffTask?.cancel()
        treeTask?.cancel()
        isLoadingFiles = false
        isLoadingHistory = false
        isLoadingDiff = false
    }

    func refresh() {
        guard isActive, let directory else { return }
        if detailMode == .content {
            content.show(directory: directory, path: selectedPath)
            content.refresh()
        }
        refreshTask?.cancel()
        refreshGeneration += 1
        let request = refreshGeneration
        isLoadingFiles = true
        refreshTask = Task {
            do {
                // Coalesce focus, fetch and operation completion notifications.
                try await Task.sleep(for: .milliseconds(150))
                let snapshot = try await GitRuntime.read(at: directory, readOnly: true) { session in
                    async let files = session.run(GitRepositoryFiles(directory: directory))
                    let revision = try await GitRuntime.runHead(in: session)
                    return try await (files, revision)
                }
                try Task.checkCancellation()
                guard request == refreshGeneration else { return }
                let changedHistory = !hasSnapshot || head != snapshot.1
                var needsRows = false
                if paths != snapshot.0 {
                    let paths = snapshot.0
                    let calculation = Task.detached(priority: .userInitiated) { ChangeFileTree(untrackedFiles: paths) }
                    let built = await withTaskCancellationHandler { await calculation.value } onCancel: { calculation.cancel() }
                    try Task.checkCancellation()
                    guard request == refreshGeneration else { return }
                    let addedDirectories = built.directoryPaths.subtracting(tree.directoryPaths)
                    tree = built
                    self.paths = paths
                    fileCount = paths.count
                    collapsedDirectories.formIntersection(tree.directoryPaths)
                    collapsedDirectories.formUnion(addedDirectories)
                    needsRows = true
                }
                if let pendingRevealPath {
                    expandParents(of: pendingRevealPath)
                    self.pendingRevealPath = nil
                    needsRows = true
                }
                if needsRows || treeTask?.isCancelled == true {
                    updateRows()
                }
                head = snapshot.1
                hasSnapshot = true
                if changedHistory {
                    histories = [:]
                    recentPaths = []
                    hasHistory = false
                }
                if let selectedPath, !paths.contains(selectedPath), detailMode == .history { selectFile(nil) }
                else if selectedPath != nil && (changedHistory || (!hasHistory && !isLoadingHistory)) { loadHistory() }
                else if diff == nil && !isLoadingDiff, let selectedEntry { selectCommit(selectedEntry) }
                isLoadingFiles = false
                error = nil
            } catch {
                guard !Task.isCancelled, request == refreshGeneration else { return }
                isLoadingFiles = false
                self.error = error
            }
        }
    }

    func revealFile(_ path: String) {
        pendingRevealPath = path
        expandParents(of: path)
        searchText = ""
        searchCollapsedDirectories = []
        updateRows()
        selectFile(path)
        revealRequest = UUID()
    }

    private func expandParents(of path: String) {
        var parent = (path as NSString).deletingLastPathComponent
        while !parent.isEmpty && parent != "." {
            collapsedDirectories.remove(parent)
            parent = (parent as NSString).deletingLastPathComponent
        }
    }

    func selectFile(_ path: String?) {
        guard selectedPath != path else { return }
        historyTask?.cancel()
        diffTask?.cancel()
        historyGeneration += 1
        diffGeneration += 1
        selectedPath = path
        entries = []
        selectedEntry = nil
        diff = nil
        canLoadMore = false
        isLoadingHistory = false
        isLoadingDiff = false
        hasHistory = false
        error = nil
        if detailMode == .content, let directory {
            content.show(directory: directory, path: path)
            return
        }
        guard let path else { return }
        if let page = histories[path] {
            entries = page.entries
            canLoadMore = page.canLoadMore
            hasHistory = true
            touchHistory(path)
            if let first = entries.first { selectCommit(first) }
        } else { loadHistory() }
    }

    func loadMore() {
        guard canLoadMore, !isLoadingHistory else { return }
        loadHistory(append: true)
    }

    private func loadHistory(append: Bool = false) {
        guard isActive, detailMode == .history, let directory, let path = selectedPath, hasSnapshot else { return }
        historyTask?.cancel()
        historyGeneration += 1
        let request = historyGeneration
        let skip = append ? entries.count : 0
        let previousSelection = selectedEntry?.id
        if !append {
            entries = []
            selectedEntry = nil
            diffTask?.cancel()
            diffGeneration += 1
            diff = nil
            isLoadingDiff = false
        }
        guard let head else {
            isLoadingHistory = false
            entries = []
            canLoadMore = false
            hasHistory = true
            return
        }
        isLoadingHistory = true
        historyTask = Task {
            do {
                let page = try await readHistory(directory, path, head, skip + pageSize + 1)
                try Task.checkCancellation()
                guard request == historyGeneration else { return }
                entries = Array(page.prefix(skip + pageSize))
                canLoadMore = page.count > skip + pageSize
                hasHistory = true
                isLoadingHistory = false
                cacheHistory(path)
                if !append, let selection = entries.first(where: { $0.id == previousSelection }) ?? entries.first {
                    selectCommit(selection)
                }
                error = nil
            } catch {
                guard !Task.isCancelled, request == historyGeneration else { return }
                isLoadingHistory = false
                self.error = error
            }
        }
    }

    func selectCommit(_ entry: FileHistoryEntry) {
        guard isActive, detailMode == .history, let directory else { return }
        diffTask?.cancel()
        diffGeneration += 1
        let request = diffGeneration
        selectedEntry = entry
        diff = nil
        error = nil
        if let cached = diffs[entry] {
            diff = cached
            recentDiffs.removeAll { $0 == entry }
            recentDiffs.append(entry)
            isLoadingDiff = false
            return
        }
        isLoadingDiff = true
        diffTask = Task {
            do {
                let patch = try await readDiff(directory, entry)
                try Task.checkCancellation()
                guard request == diffGeneration else { return }
                diff = patch
                isLoadingDiff = false
                if patch.raw.utf8.count <= 2 * 1_024 * 1_024 {
                    diffs[entry] = patch
                    recentDiffs.append(entry)
                    while recentDiffs.count > 6 || diffs.values.reduce(0, { $0 + $1.raw.utf8.count }) > 8 * 1_024 * 1_024 {
                        diffs[recentDiffs.removeFirst()] = nil
                    }
                }
            } catch {
                guard !Task.isCancelled, request == diffGeneration else { return }
                isLoadingDiff = false
                self.error = error
            }
        }
    }

    func selectDetailMode(_ mode: RepositoryFileDetailMode) {
        guard detailMode != mode else { return }
        detailMode = mode
        if mode == .content {
            historyGeneration += 1
            diffGeneration += 1
            historyTask?.cancel()
            diffTask?.cancel()
            isLoadingHistory = false
            isLoadingDiff = false
            if isActive, let directory { content.show(directory: directory, path: selectedPath) }
        } else {
            content.hide()
            if !hasHistory { loadHistory() }
            else if diff == nil, let selectedEntry { selectCommit(selectedEntry) }
        }
    }

    func search(_ text: String) {
        searchText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        searchCollapsedDirectories = []
        updateRows(debounce: true)
    }

    func isDirectoryCollapsed(_ path: String) -> Bool {
        (searchText.isEmpty ? collapsedDirectories : searchCollapsedDirectories).contains(path)
    }

    func toggleDirectory(_ path: String) {
        if searchText.isEmpty {
            if !collapsedDirectories.insert(path).inserted { collapsedDirectories.remove(path) }
        } else {
            if !searchCollapsedDirectories.insert(path).inserted { searchCollapsedDirectories.remove(path) }
        }
        updateRows()
    }

    func collapseDirectories() {
        if searchText.isEmpty { collapsedDirectories = tree.directoryPaths }
        else { searchCollapsedDirectories = tree.directoryPaths }
        updateRows()
    }

    private func updateRows(debounce: Bool = false) {
        treeTask?.cancel()
        treeGeneration += 1
        let request = treeGeneration
        let tree = tree
        let paths = paths
        let collapsed = searchText.isEmpty ? collapsedDirectories : searchCollapsedDirectories
        let text = searchText
        treeTask = Task {
            do {
                if debounce { try await Task.sleep(for: .milliseconds(150)) }
                let calculation = Task.detached(priority: .userInitiated) {
                    if text.isEmpty { return tree.visibleRows(collapsedDirectories: collapsed) }
                    let matches = paths.filter { $0.localizedStandardContains(text) }
                    return ChangeFileTree(untrackedFiles: matches).visibleRows(collapsedDirectories: collapsed)
                }
                let result = await withTaskCancellationHandler { await calculation.value } onCancel: { calculation.cancel() }
                try Task.checkCancellation()
                guard request == treeGeneration else { return }
                rows = result
            } catch { /* A newer search or directory expansion owns the result. */ }
        }
    }

    private func touchHistory(_ path: String) {
        recentPaths.removeAll { $0 == path }
        recentPaths.append(path)
    }

    private func cacheHistory(_ path: String) {
        let textBytes = entries.reduce(0) { total, entry in
            let commit = entry.commit
            let fields = [commit.hash, commit.author, commit.authorEmail, commit.authorDate, commit.title, commit.body]
                + commit.parentHashes + [entry.oldPath, entry.newPath].compactMap { $0 }
            return total + fields.reduce(0) { $0 + $1.utf8.count }
        }
        if entries.count <= 1_000 && textBytes <= 1_024 * 1_024 {
            histories[path] = Page(entries: entries, canLoadMore: canLoadMore, textBytes: textBytes)
            touchHistory(path)
        } else {
            histories[path] = nil
            recentPaths.removeAll { $0 == path }
        }
        while recentPaths.count > 8 || histories.values.reduce(0, { $0 + $1.entries.count }) > 1_000
            || histories.values.reduce(0, { $0 + $1.textBytes }) > 4 * 1_024 * 1_024 {
            histories[recentPaths.removeFirst()] = nil
        }
    }
}

private extension GitRuntime {
    static func runHead(in session: GitRuntime.Session) async throws -> String? {
        let value = try await session.run(GitHeadRevision(directory: session.directory))
        return value.isEmpty ? nil : value
    }
}

private struct GitHeadRevision: RepositoryCommand {
    var directory: URL
    var isReadOnly: Bool { true }
    var arguments: [String] { ["git", "rev-parse", "--revs-only", "HEAD"] }
    func parse(for output: String) -> String { output.trimmingCharacters(in: .whitespacesAndNewlines) }
}
