import AppKit
import FoldGitCore
import FoldGitTestSupport
import Foundation
import SwiftUI
import Testing
@testable import FoldGit

@MainActor
struct HistoryStoreTests {
    @Test func openingCleanRepositorySelectsLatestCommit() async throws {
        let repository = try await TestRepository.create(commits: 3)
        defer { repository.remove() }
        let latestHash = try await repository.git(["rev-parse", "HEAD"])
        let selection = try await initialSelection(in: repository)
        #expect(selection.id == latestHash)
    }

    @Test func openingRepositoryWithUntrackedStagedOrUnstagedChangesSelectsWorkingTree() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }

        try repository.write("new.swift", "let added = true\n")
        #expect(try await initialSelection(in: repository) == .notCommitted)

        try await repository.git(["add", "new.swift"])
        #expect(try await initialSelection(in: repository) == .notCommitted)

        try await repository.commit("feat: tracked file")
        try repository.write("new.swift", "let added = false\n")
        #expect(try await initialSelection(in: repository) == .notCommitted)
    }

    private func initialSelection(in repository: TestRepository) async throws -> Log {
        var selection: Log?
        let view = RepositoryScreen(
            folder: WorkspaceEntry(url: repository.url),
            selectionLog: Binding(get: { selection }, set: { selection = $0 }),
            subSelectionLogID: .constant(nil),
            isRefresh: .constant(false)
        )
        .environment(\.folder, repository.url)
        .environment(WorktreeStore())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderBack(nil)
        defer { window.close() }
        for _ in 0..<100 {
            if let selection { return selection }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try #require(selection)
    }

    @Test func paginationSearchAndNavigationUseRealRepositories() async throws {
        let repository = try await TestRepository.create(commits: 7)
        defer { repository.remove() }
        let store = HistoryStore()
        store.directory = repository.url
        store.number = 3
        await store.refresh()
        #expect(store.error == nil)
        #expect(store.commits.count == 3)
        #expect(store.totalCommitsCount == 7)
        #expect(store.nextLogID(logID: store.commits[0].id) == store.commits[1].id)
        #expect(store.previousLogID(logID: store.commits[1].id) == store.commits[0].id)
        await store.loadMore()
        #expect(store.commits.count == 6)
        await store.loadMore()
        #expect(store.commits.count == 7)
        #expect(!store.canLoadMore)
        store.search("commit 2")
        await store.searchTask?.value
        #expect(store.commits.map(\.title) == ["feat: commit 2"])
        #expect(store.totalCommitsCount == 1)
    }

    @Test func updatesIncludeWorkingChangesAndDoNotKeepOldErrors() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        let store = HistoryStore()
        store.directory = repository.url
        store.error = GitExecutionError(description: "old error")
        try repository.write("中文 file.swift", "let value = 2\n")
        await store.refresh()
        #expect(store.error == nil)
        #expect(store.logs().first == .notCommitted)
        #expect(store.notCommitted?.status.untrackedFiles == ["中文 file.swift"])
        try await repository.commit("fix: second")
        await store.update()
        #expect(store.commits.count == 2)
        #expect(store.logs().first == .committed(store.commits[0]))
    }

    @Test func staleRefreshCannotOverwriteAnotherRepository() async throws {
        let first = try await TestRepository.create(commits: 5)
        let second = try await TestRepository.create(commits: 1)
        defer { first.remove(); second.remove() }
        let store = HistoryStore()
        store.directory = first.url
        let old = Task { await store.refresh() }
        await Task.yield()
        store.directory = second.url
        await store.refresh()
        await old.value
        #expect(store.totalCommitsCount == 1)
        #expect(store.commits.count == 1)
    }

    @Test func liveSearchDebouncesCancelsCompositionAndRestoresWorkingTree() async throws {
        let repository = try await TestRepository.create(commits: 7)
        defer { repository.remove() }
        let store = HistoryStore()
        store.directory = repository.url
        store.number = 2
        try repository.write("draft.swift", "let draft = true")
        await store.refresh()
        store.search("ni", isComposing: true)
        #expect(store.searchText.isEmpty)
        #expect(!store.isSearching)
        #expect(store.totalCommitsCount == 7)
        store.search("commit 0")
        let stale = store.searchTask
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.totalCommitsCount == 7)
        store.search("commit 1")
        await stale?.value
        await store.searchTask?.value
        #expect(store.commits.map(\.title) == ["feat: commit 1"])
        #expect(store.totalCommitsCount == 1)
        #expect(!store.logs().contains(.notCommitted))
        store.search("commit 3")
        let interrupted = store.searchTask
        store.search("zhong", isComposing: true)
        await interrupted?.value
        #expect(store.commits.map(\.title) == ["feat: commit 1"])
        store.search("")
        await store.searchTask?.value
        #expect(store.totalCommitsCount == 7)
        #expect(store.commits.count == 2)
        #expect(store.logs().first == .notCommitted)
    }

    @Test func liveSearchMatchesEarlierHistoryAndRefreshesAfterNewCommits() async throws {
        let repository = try await TestRepository.create(commits: 7)
        defer { repository.remove() }
        let store = HistoryStore()
        store.directory = repository.url
        store.number = 2
        await store.refresh()
        store.search("COMMIT")
        await store.searchTask?.value
        #expect(store.totalCommitsCount == 7)
        #expect(store.commits.count == 2)
        await store.loadMore()
        #expect(store.commits.map(\.title) == ["feat: commit 6", "feat: commit 5", "feat: commit 4", "feat: commit 3"])
        store.search("commit 0")
        await store.searchTask?.value
        #expect(store.commits.map(\.title) == ["feat: commit 0"])
        store.search("中文")
        await store.searchTask?.value
        #expect(store.totalCommitsCount == 0)
        try await repository.commit("fix: 中文搜索")
        await store.refresh()
        #expect(store.commits.map(\.title) == ["fix: 中文搜索"])
        #expect(store.error == nil)
    }

    @Test func nativeEditorOnlySubmitsCJKAfterCompositionCommits() async throws {
        var text = ""
        var events: [(String, Bool)] = []
        let content = NativeSearchField(text: Binding(get: { text }, set: { text = $0 }), placeholder: "Search",
                                        accessibilityIdentifier: "testSearchField", focusRequest: UUID()) {
            events.append(($0, $1))
        }.frame(width: 360, height: 30)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        func findField(_ view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField { return field }
            return view.subviews.compactMap(findField).first
        }
        let field = try #require(findField(host))
        #expect(field.isEditable)
        #expect(field.isBezeled == NSSearchField().isBezeled)
        #expect(field.bezelStyle == NSSearchField().bezelStyle)
        try await Task.sleep(for: .milliseconds(50))
        #expect(window.makeFirstResponder(field))
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? MarkedTextSearchEditor)
        for candidate in ["你", "日本語", "한국어"] {
            editor.selectAll(nil)
            events = []
            editor.setMarkedText(candidate, selectedRange: NSRange(location: candidate.utf16.count, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(editor.hasMarkedText())
            #expect(events.allSatisfy { $0.1 })
            editor.unmarkText()
            #expect(events.last?.0 == candidate)
            #expect(events.last?.1 == false)
            #expect(text == candidate)
        }
        editor.selectAll(nil)
        editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        events = []
        editor.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(events.last?.0 == "中文")
        #expect(events.last?.1 == false)
        #expect(events.filter { !$0.1 }.count == 1)
    }


    @Test func historyScopePersistsPerRepositoryAndSearchUsesTheSelectedScope() async throws {
        let repository = try await TestRepository.create(commits: 3)
        let otherRepository = try await TestRepository.create()
        defer { repository.remove(); otherRepository.remove() }
        try await repository.git(["switch", "-c", "feature"])
        try await repository.commit("feat: remote preview searchable")
        let feature = try await repository.git(["rev-parse", "HEAD"])
        try await repository.git(["switch", "main"])
        let name = "FoldGit.HistoryScopeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = HistoryStore(defaults: defaults)
        store.directory = repository.url
        store.number = 2
        await store.refresh()
        #expect(store.scope == .currentBranch)
        #expect(store.totalCommitsCount == 3)
        store.search("preview")
        await store.searchTask?.value
        #expect(store.commits.isEmpty)
        await store.setScope(.allCommits)
        #expect(store.commits.map(\.hash) == [feature])
        #expect(store.isOutsideCurrentBranch(feature))
        #expect(!store.isIncoming(feature))
        store.search("")
        await store.searchTask?.value
        #expect(store.totalCommitsCount == 4)
        await store.loadMore()
        #expect(store.commits.count == 4)
        let restored = HistoryStore(defaults: defaults)
        restored.directory = repository.url
        #expect(restored.scope == .allCommits)
        restored.directory = otherRepository.url
        #expect(restored.scope == .currentBranch)
        restored.directory = repository.url
        #expect(restored.scope == .allCommits)
    }

    @Test func incomingRevealLoadsBeyondFirstPageAndRefreshPreservesTheLoadedHistory() async throws {
        let remote = try await TestRepository.create()
        let local = try await TestRepository.create(commits: 0)
        defer { remote.remove(); local.remove() }
        try await local.git(["remote", "add", "team", remote.url.path])
        try await local.git(["fetch", "team"])
        try await local.git(["reset", "--hard", "team/main"])
        try await local.git(["branch", "--set-upstream-to=team/main"])
        try await remote.commit("feat: incoming preview")
        let incoming = try await remote.git(["rev-parse", "HEAD"])
        // A later unrelated branch must not hide the incoming target behind pagination.
        try await local.git(["switch", "-c", "unrelated"])
        for index in 0..<8 {
            _ = try await GitRuntime.run(arguments: ["git", "commit", "--allow-empty", "-m", "other \(index)"],
                                     currentDirectoryURL: local.url,
                                     environment: ["GIT_COMMITTER_DATE": "2030-01-01T00:00:00Z"])
        }
        try await local.git(["switch", "main"])
        try await local.git(["fetch", "team"])
        let name = "FoldGit.IncomingRevealTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = HistoryStore(defaults: defaults)
        store.directory = local.url
        store.number = 2
        await store.refresh()
        #expect(store.snapshot?.incoming == [incoming])
        await store.setScope(.allCommits)
        #expect(!store.commits.contains { $0.hash == incoming })
        store.search("not found")
        await store.searchTask?.value
        let target = await store.revealIncoming()
        #expect(store.error == nil)
        #expect(target == incoming)
        #expect(store.searchText.isEmpty)
        #expect(store.scope == .allCommits)
        #expect(store.commits.count > store.number)
        #expect(store.commits.contains { $0.id == incoming })
        #expect(store.isIncoming(incoming))
        #expect(store.scrollRequest?.target == incoming)
        let loadedCount = store.commits.count
        await store.refresh()
        #expect(store.commits.count == loadedCount)
        try await local.git(["merge", "--ff-only", "team/main"])
        await store.refresh()
        #expect(!store.isIncoming(incoming))
        #expect(!store.isOutsideCurrentBranch(incoming))
    }

    @Test func openingRepositoryRefreshesFetchedHistoryBeforeFinishing() async throws {
        let remote = try await TestRepository.create()
        let local = try await TestRepository.create(commits: 0)
        defer { remote.remove(); local.remove() }
        try await local.git(["remote", "add", "team", remote.url.path])
        try await local.git(["fetch", "team"])
        try await local.git(["reset", "--hard", "team/main"])
        try await local.git(["branch", "--set-upstream-to=team/main"])
        try await remote.commit("feat: fetched on opening")
        let incoming = try await remote.git(["rev-parse", "HEAD"])
        let name = "FoldGit.FetchHistoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let session = RepositorySession()
        session.history = HistoryStore(defaults: defaults)
        await session.refresh(in: local.url, fetchRemote: true)
        #expect(session.error == nil)
        #expect(session.remote.tracking?.behind == 1)
        #expect(session.history.isIncoming(incoming))
        let target = await session.history.revealIncoming()
        #expect(target == incoming)
        #expect(session.history.commits.first?.hash == incoming)
    }

    @Test func revealHeadClearsSearchAndLoadsPastOtherBranches() async throws {
        let repository = try await TestRepository.create(commits: 3)
        defer { repository.remove() }
        let head = try await repository.git(["rev-parse", "HEAD"])
        try await repository.git(["switch", "-c", "newer-branch"])
        for index in 0..<5 {
            _ = try await GitRuntime.run(arguments: ["git", "commit", "--allow-empty", "-m", "other \(index)"],
                currentDirectoryURL: repository.url, environment: ["GIT_COMMITTER_DATE": "2030-01-01T00:00:00Z"])
        }
        try await repository.git(["switch", "main"])
        let name = "FoldGit.MenuNavigationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = HistoryStore(defaults: defaults)
        store.directory = repository.url
        store.number = 2
        await store.setScope(.allCommits)
        #expect(!store.commits.contains { $0.hash == head })
        store.search("missing search result")
        await store.searchTask?.value
        #expect(await store.revealHead() == head)
        #expect(store.error == nil)
        #expect(store.searchText.isEmpty)
        #expect(store.scope == .allCommits)
        #expect(store.commits.contains { $0.hash == head })
        #expect(store.scrollRequest?.target == head)
    }

    @Test func revealWorkingTreeRestoresChangesHiddenBySearch() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        try repository.write("menu-navigation.txt", "untracked change\n")
        let store = HistoryStore()
        store.directory = repository.url
        await store.refresh()
        store.search("missing search result")
        await store.searchTask?.value
        #expect(!store.logs().contains(.notCommitted))
        await store.revealWorkingTree()
        #expect(store.searchText.isEmpty)
        #expect(store.logs().first == .notCommitted)
        #expect(store.scrollRequest?.target == Log.notCommitted.id)
        #expect(store.notCommitted?.status.untrackedFiles == ["menu-navigation.txt"])
    }
}
