import AppKit
import FoldGitCore
import FoldGitTestSupport
import SwiftUI
import Testing
@testable import FoldGit

@MainActor
struct FileHistoryStoreTests {
    @Test func demandLoadingPaginationCachesAndRefreshInvalidation() async throws {
        let repository = try await TestRepository.create(commits: 6)
        defer { repository.remove() }
        let store = FileHistoryStore(pageSize: 2)
        await GitCommandLog.shared.clear(in: repository.url)
        store.refresh()
        #expect(await GitCommandLog.shared.records(in: repository.url).isEmpty)
        store.activate(in: repository.url)
        await store.refreshTask?.value
        await store.treeTask?.value
        #expect(store.fileCount == 1)
        #expect(store.entries.isEmpty)
        #expect(await historyCommands(in: repository).isEmpty)
        store.deactivate()
        store.activate(in: repository.url)
        await store.refreshTask?.value
        await store.treeTask?.value
        #expect(store.rows.map(\.path) == ["example.swift"])
        store.selectFile("example.swift")
        await settle(store)
        #expect(store.entries.count == 2)
        #expect(store.canLoadMore)
        #expect(store.diff?.fileDiffs.count == 1)
        store.loadMore()
        await settle(store)
        #expect(store.entries.count == 4)
        store.loadMore()
        await settle(store)
        #expect(store.entries.count == 6)
        #expect(!store.canLoadMore)
        let previousQueries = await historyCommands(in: repository).count
        let selected = try #require(store.selectedEntry)
        store.selectFile(nil)
        store.selectFile("example.swift")
        await settle(store)
        #expect(store.selectedEntry == selected)
        #expect(await historyCommands(in: repository).count == previousQueries)
        // A save changes working content, but the committed history remains valid.
        try repository.write("example.swift", "let draft = true\n")
        store.refresh()
        store.refresh()
        store.refresh()
        await store.refreshTask?.value
        await settle(store)
        #expect(await historyCommands(in: repository).count == previousQueries)
        try await repository.commit("new committed value")
        store.refresh()
        await store.refreshTask?.value
        await settle(store)
        #expect(store.entries.first?.commit.title == "new committed value")
        #expect(await historyCommands(in: repository).count == previousQueries + 1)
        #expect(store.error == nil)
        store.deactivate()
        let previousCommands = await GitCommandLog.shared.records(in: repository.url).count
        store.refresh()
        #expect(await GitCommandLog.shared.records(in: repository.url).count == previousCommands)
    }

    @Test func historyAndDiffCachesEvictOlderEntries() async throws {
        let repository = try await TestRepository.create(commits: 7)
        defer { repository.remove() }
        for index in 0..<9 { try repository.write("File\(index).txt", "value\n") }
        try await repository.commit("add cache fixtures")
        let store = FileHistoryStore()
        store.activate(in: repository.url)
        await store.refreshTask?.value
        store.selectFile("example.swift")
        await settle(store)
        let first = try #require(store.entries.first)
        for entry in store.entries { store.selectCommit(entry); await store.diffTask?.value }
        let patches = await GitCommandLog.shared.records(in: repository.url).filter { $0.command.contains("--no-textconv") }.count
        store.selectCommit(first)
        await store.diffTask?.value
        #expect(await GitCommandLog.shared.records(in: repository.url).filter { $0.command.contains("--no-textconv") }.count == patches + 1)
        for index in 0..<9 { store.selectFile("File\(index).txt"); await settle(store) }
        let queries = await historyCommands(in: repository).count
        store.selectFile("example.swift")
        await settle(store)
        #expect(await historyCommands(in: repository).count == queries + 1)
        store.deactivate()
    }

    @Test func directoriesStartCollapsedAndRefreshPreservesOnlyManualExpansion() async throws {
        let repository = try await TestRepository.create(commits: 0)
        defer { repository.remove() }
        try repository.write("Sources/Nested/file.swift", "source")
        try repository.write("Tests/test.swift", "test")
        try repository.write("README.md", "readme")
        let store = FileHistoryStore()
        store.activate(in: repository.url)
        await store.refreshTask?.value
        await store.treeTask?.value
        #expect(store.rows.map(\.path) == ["Sources", "Tests", "README.md"])
        #expect(store.collapsedDirectories == ["Sources", "Sources/Nested", "Tests"])

        store.toggleDirectory("Sources")
        await store.treeTask?.value
        #expect(store.rows.map(\.path) == ["Sources", "Sources/Nested", "Tests", "README.md"])
        store.toggleDirectory("Sources/Nested")
        await store.treeTask?.value
        #expect(store.rows.contains { $0.path == "Sources/Nested/file.swift" })

        try repository.write("Sources/New/new.swift", "new")
        try repository.write("Other/other.txt", "other")
        store.refresh()
        await store.refreshTask?.value
        await store.treeTask?.value
        #expect(!store.isDirectoryCollapsed("Sources"))
        #expect(!store.isDirectoryCollapsed("Sources/Nested"))
        #expect(store.isDirectoryCollapsed("Sources/New"))
        #expect(store.isDirectoryCollapsed("Other"))
        #expect(!store.rows.contains { $0.path == "Sources/New/new.swift" })

        store.collapseDirectories()
        await store.treeTask?.value
        #expect(store.rows.map(\.path) == ["Other", "Sources", "Tests", "README.md"])
        store.search("new.swift")
        await store.treeTask?.value
        #expect(store.rows.map(\.path) == ["Sources", "Sources/New", "Sources/New/new.swift"])
        store.search("")
        await store.treeTask?.value
        #expect(store.rows.map(\.path) == ["Other", "Sources", "Tests", "README.md"])
        store.deactivate()
    }

    @Test func emptyRepositoriesSearchAndRemovingSelection() async throws {
        let repository = try await TestRepository.create(commits: 0)
        defer { repository.remove() }
        try repository.write("Sources/中文 file.swift", "new file")
        try repository.write("Other/other.txt", "other file")
        let store = FileHistoryStore()
        store.activate(in: repository.url)
        await store.refreshTask?.value
        await store.treeTask?.value
        #expect(store.fileCount == 2)
        store.collapseDirectories()
        await store.treeTask?.value
        #expect(store.rows.allSatisfy { $0.isDirectory })
        store.search("中文")
        await store.treeTask?.value
        #expect(store.rows.map(\.path) == ["Sources", "Sources/中文 file.swift"])
        store.toggleDirectory("Sources")
        await store.treeTask?.value
        #expect(store.rows.map(\.path) == ["Sources"])
        store.search("")
        await store.treeTask?.value
        #expect(store.rows.allSatisfy { $0.isDirectory })
        store.selectFile("Sources/中文 file.swift")
        await settle(store)
        #expect(store.entries.isEmpty)
        #expect(!store.isLoadingHistory)
        try FileManager.default.removeItem(at: repository.url.appendingPathComponent("Sources/中文 file.swift"))
        store.refresh()
        await store.refreshTask?.value
        #expect(store.selectedPath == nil)
        #expect(store.diff == nil)
        store.deactivate()
    }

    @Test func refreshDoesNotRestartAnUnchangedInFlightHistoryQuery() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        let probe = ReaderProbe()
        let store = FileHistoryStore(readHistory: { _, _, _, _ in
            await probe.start()
            try await Task.sleep(for: .milliseconds(500))
            return []
        })
        store.activate(in: repository.url)
        await store.refreshTask?.value
        store.selectFile("example.swift")
        try await Task.sleep(for: .milliseconds(50))
        store.refresh()
        await store.refreshTask?.value
        await store.historyTask?.value
        #expect(await probe.count == 1)
        #expect(!store.isLoadingHistory)
        store.deactivate()
    }

    @Test func cancellationStopsReaderAndAllowsRepositoryWrite() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        let probe = ReaderProbe()
        let store = FileHistoryStore(readHistory: { directory, _, _, _ in
            await probe.start()
            _ = try await GitRuntime.run(arguments: ["/bin/sleep", "30"], currentDirectoryURL: directory, readOnly: true)
            return []
        })
        store.activate(in: repository.url)
        await store.refreshTask?.value
        store.selectFile("example.swift")
        for _ in 0..<100 {
            if await probe.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await probe.started)
        store.suspendQueries()
        let clock = ContinuousClock()
        let start = clock.now
        // A write has exclusive access and can complete only after the canceled reader releases its slot.
        _ = try await repository.git(["config", "foldgit.cancellation-test", "passed"])
        await store.historyTask?.value
        #expect(start.duration(to: clock.now) < .seconds(3))
        #expect(store.entries.isEmpty)
        #expect(!store.isLoadingHistory)
        #expect(store.error == nil)
        store.deactivate()
    }

    @Test func staleRepositoryAndSelectionCannotPublishOldResults() async throws {
        let first = try await TestRepository.create(commits: 4)
        let second = try await TestRepository.create(commits: 1)
        defer { first.remove(); second.remove() }
        let store = FileHistoryStore()
        store.activate(in: first.url)
        let old = store.refreshTask
        store.activate(in: second.url)
        await old?.value
        await store.refreshTask?.value
        store.selectFile("example.swift")
        let oldHistory = store.historyTask
        store.selectFile(nil)
        await oldHistory?.value
        #expect(store.directory == second.url)
        #expect(store.selectedEntry == nil)
        #expect(store.diff == nil)
        #expect(store.entries.isEmpty)
        store.selectFile("example.swift")
        await settle(store)
        #expect(store.entries.count == 1)
        store.deactivate()
    }

    @Test func browserRendersInBothAppearancesAndBuildsLargeTreesOffMainActor() async throws {
        let repository = try await TestRepository.create(commits: 3)
        defer { repository.remove() }
        let store = FileHistoryStore()
        store.activate(in: repository.url)
        await store.refreshTask?.value
        await store.treeTask?.value
        store.selectFile("example.swift")
        await settle(store)
        for scheme in [ColorScheme.light, .dark] {
            let root = HStack(spacing: 0) {
                RepositoryFileTreeView(store: store).frame(width: 320)
                Divider()
                FileHistoryDetailView(store: store)
            }
            .environment(\.folder, repository.url)
            .environment(\.colorScheme, scheme)
            .frame(width: 960, height: 700)
            let view = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 700),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(150))
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            #expect(view.fittingSize.width <= 960)
            if let output = ProcessInfo.processInfo.environment["FILE_HISTORY_SNAPSHOT_DIRECTORY"] {
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("file-history-\(scheme).png"))
            }
        }
        store.deactivate()
        let clock = ContinuousClock()
        let start = clock.now
        let rows = await Task.detached {
            ChangeFileTree(untrackedFiles: (0..<10_000).map { "Sources/Module\($0 / 100)/File\($0).swift" }).rows
        }.value
        #expect(rows.count == 10_101)
        print("File history benchmark: 10,000-file tree built in \(start.duration(to: clock.now))")
    }

    private func settle(_ store: FileHistoryStore) async {
        await store.historyTask?.value
        await store.diffTask?.value
    }

    private func historyCommands(in repository: TestRepository) async -> [GitCommandLogEntry] {
        await GitCommandLog.shared.records(in: repository.url).filter { $0.command.contains("--follow") }
    }
}

private actor ReaderProbe {
    private(set) var started = false
    private(set) var count = 0
    func start() { started = true; count += 1 }
}
