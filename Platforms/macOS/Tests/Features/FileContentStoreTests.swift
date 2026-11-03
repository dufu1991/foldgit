import FoldGitTestSupport
import Foundation
import Testing
@testable import FoldGit

@MainActor
struct FileContentStoreTests {
    @Test func missingWorkspaceFilesDoNotNavigateAndRestoredFilesCanBeOpened() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        let untrackedPath = "New Folder/untracked.txt"
        try repository.write(untrackedPath, "untracked\n")
        var openedPaths: [String] = []
        let open = OpenWorkspaceFileAction(directory: repository.url) { openedPaths.append($0) }

        for path in ["example.swift", untrackedPath] {
            #expect(open(path))
            let count = openedPaths.count
            try FileManager.default.removeItem(at: repository.url.appendingPathComponent(path))
            #expect(!open(path))
            #expect(openedPaths.count == count)
            try repository.write(path, "restored\n")
            #expect(open(path))
            #expect(openedPaths.last == path)
        }
        let count = openedPaths.count
        #expect(!open("Deleted Folder/Nested/missing.txt"))
        #expect(openedPaths.count == count)
    }

    @Test(arguments: [true, false])
    func filesDeletedAfterNavigationKeepTheMissingStateAndCanBeRetried(tracked: Bool) async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        let path = tracked ? "example.swift" : "New Folder/untracked.txt"
        if !tracked { try repository.write(path, "untracked\n") }
        let store = FileHistoryStore()
        defer { store.deactivate() }
        let open = OpenWorkspaceFileAction(directory: repository.url) { path in
            store.activate(in: repository.url)
            store.selectDetailMode(.content)
            store.revealFile(path)
        }
        #expect(open(path))
        try FileManager.default.removeItem(at: repository.url.appendingPathComponent(path))
        await store.refreshTask?.value
        await store.treeTask?.value
        await store.content.readTask?.value
        #expect(store.selectedPath == path)
        #expect(store.detailMode == .content)
        guard case .missing = store.content.state else {
            Issue.record("A file deleted during navigation must show the missing state")
            return
        }

        store.refresh()
        await store.refreshTask?.value
        await store.content.refreshTask?.value
        #expect(store.selectedPath == path)
        guard case .missing = store.content.state else {
            Issue.record("Refreshing must preserve the missing state")
            return
        }
        try repository.write(path, "restored content\n")
        store.content.load()
        await store.content.readTask?.value
        guard case .text(let document) = store.content.state else {
            Issue.record("Retry must load the restored file")
            return
        }
        #expect(document.text == "restored content\n")
    }

    @Test func revealingFilesAfterReturningToACachedTreeShowsNewDirectoriesAndWorkingContent() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        let committedPath = "Sources/Nested/committed.txt"
        let untrackedPath = "New Folder/Nested/untracked.txt"
        try repository.write(committedPath, "committed content\n")
        try await repository.commit("add nested file")
        let store = FileHistoryStore()
        store.activate(in: repository.url)
        await store.refreshTask?.value
        await store.treeTask?.value
        store.search("example")
        await store.treeTask?.value
        store.deactivate()

        try repository.write(committedPath, "working content\n")
        try repository.write(untrackedPath, "untracked content\n")
        for (path, expected) in [(untrackedPath, "untracked content\n"), (committedPath, "working content\n")] {
            store.activate(in: repository.url)
            store.selectDetailMode(.content)
            store.revealFile(path)
            await store.refreshTask?.value
            await store.treeTask?.value
            await store.content.readTask?.value
            #expect(store.selectedPath == path)
            #expect(store.searchText.isEmpty)
            #expect(store.rows.contains { $0.path == path && !$0.isDirectory })
            #expect(!store.isDirectoryCollapsed((path as NSString).deletingLastPathComponent))
            #expect(store.entries.isEmpty)
            guard case .text(let document) = store.content.state else {
                Issue.record("Revealed working tree file did not load")
                store.deactivate()
                return
            }
            #expect(document.text == expected)

            let request = try #require(store.revealRequest)
            store.collapseDirectories()
            await store.treeTask?.value
            store.revealFile(path)
            await store.treeTask?.value
            #expect(store.revealRequest != request)
            #expect(store.rows.contains { $0.path == path && !$0.isDirectory })
            store.deactivate()
        }
    }

    @Test func revealingAFileDuringInitialLoadExpandsItsDirectoriesAndLoadsContentOnly() async throws {
        let repository = try await TestRepository.create(commits: 0)
        defer { repository.remove() }
        try repository.write("Sources/Nested/file.json", "{\"enabled\":true}\n")
        let store = FileHistoryStore()
        store.activate(in: repository.url)
        store.selectDetailMode(.content)
        store.revealFile("Sources/Nested/file.json")
        await store.refreshTask?.value
        await store.treeTask?.value
        await store.content.readTask?.value
        #expect(store.selectedPath == "Sources/Nested/file.json")
        #expect(store.rows.contains { $0.path == "Sources/Nested/file.json" })
        #expect(!store.isDirectoryCollapsed("Sources"))
        #expect(!store.isDirectoryCollapsed("Sources/Nested"))
        #expect(store.entries.isEmpty)
        #expect(store.historyTask == nil)
        guard case .text(let document) = store.content.state else {
            Issue.record("Revealed file did not load")
            return
        }
        #expect(document.text == "{\"enabled\":true}\n")
        store.deactivate()
    }

    @Test func contentIsDemandLoadedAndModeResetsOnlyForANewRepository() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        let store = FileHistoryStore()
        #expect(store.detailMode == .history)
        store.activate(in: repository.url)
        await store.refreshTask?.value
        store.selectFile("example.swift")
        await store.historyTask?.value
        await store.diffTask?.value
        #expect(store.content.url == nil)
        let selected = store.selectedEntry
        let patch = store.diff
        try repository.write("example.swift", "let draft = \"中文 😀\"\n")
        store.selectDetailMode(.content)
        await store.content.readTask?.value
        guard case .text(let document) = store.content.state else {
            Issue.record("Working tree content did not load")
            return
        }
        #expect(document.text == "let draft = \"中文 😀\"\n")
        store.selectDetailMode(.history)
        #expect(store.selectedEntry == selected)
        #expect(store.diff == patch)
        #expect(store.content.url == nil)
        store.selectDetailMode(.content)
        try repository.write("other.txt", "other")
        store.selectFile("other.txt")
        await store.content.readTask?.value
        #expect(store.detailMode == .content)
        guard case .text(let other) = store.content.state else {
            Issue.record("Next file did not load")
            return
        }
        #expect(other.text == "other")
        store.deactivate()
        #expect(store.content.url == nil)
        store.activate(in: repository.url)
        #expect(store.detailMode == .content)
        let second = try await TestRepository.create()
        defer { second.remove() }
        store.activate(in: second.url)
        #expect(store.detailMode == .history)
        #expect(store.selectedPath == nil)
        #expect(store.content.url == nil)
        store.deactivate()
    }

    @Test func refreshOnlyRereadsSelectedFileWhenItsFingerprintChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("current.txt")
        try Data("first".utf8).write(to: url)
        let probe = ContentReadProbe()
        let store = FileContentStore(reader: { url, large in
            await probe.record()
            return try FileContentReader.read(url, allowLarge: large)
        })
        store.show(directory: directory, path: "current.txt")
        await store.readTask?.value
        #expect(await probe.count == 1)
        store.show(directory: directory, path: "current.txt")
        store.refresh()
        store.refresh()
        await store.refreshTask?.value
        #expect(await probe.count == 1)
        try Data("unrelated".utf8).write(to: directory.appendingPathComponent("other.txt"))
        store.refresh()
        await store.refreshTask?.value
        #expect(await probe.count == 1)
        try Data("second content".utf8).write(to: url, options: .atomic)
        store.refresh()
        await store.refreshTask?.value
        await store.readTask?.value
        #expect(await probe.count == 2)
        guard case .text(let document) = store.state else {
            Issue.record("Changed content was not loaded")
            return
        }
        #expect(document.text == "second content")
        try FileManager.default.removeItem(at: url)
        store.refresh()
        await store.refreshTask?.value
        guard case .missing = store.state else {
            Issue.record("Deleted file was not reported")
            return
        }
        try Data("restored".utf8).write(to: url)
        store.load()
        await store.readTask?.value
        guard case .text(let restored) = store.state else {
            Issue.record("Retry did not restore content")
            return
        }
        #expect(restored.text == "restored")
        store.hide()
    }

    @Test func staleReadCannotOverwriteNewSelectionOrHiddenState() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("snapshot".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let metadata = try FileContentReader.inspect(url)
        let gate = ContentReadGate()
        let store = FileContentStore(reader: { url, _ in
            if url.lastPathComponent == "old.txt" { await gate.wait() }
            return FileContentSnapshot(metadata: metadata, content: .text(url.lastPathComponent, plain: false))
        })
        store.show(directory: url.deletingLastPathComponent(), path: "old.txt")
        let oldTask = store.readTask
        await gate.started()
        store.show(directory: url.deletingLastPathComponent(), path: "new.txt")
        await store.readTask?.value
        await gate.release()
        await oldTask?.value
        guard case .text(let document) = store.state else {
            Issue.record("New selection did not load")
            return
        }
        #expect(document.text == "new.txt")
        store.show(directory: url.deletingLastPathComponent(), path: "old.txt")
        let hiddenTask = store.readTask
        store.hide()
        await hiddenTask?.value
        #expect(store.url == nil)
        #expect(store.metadata == nil)
        guard case .idle = store.state else { Issue.record("Hidden content was repopulated"); return }
    }
}

private actor ContentReadProbe {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor ContentReadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    private var released = false
    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func started() async {
        while !entered { await Task.yield() }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
