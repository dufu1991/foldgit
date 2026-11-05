import AppKit
import FoldGitCore
import FoldGitTestSupport
import SwiftUI
import Testing
@testable import FoldGit

@MainActor
struct CommandLogPanelTests {
    @Test func filtersAndExportsPreserveFailureDetails() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        await GitCommandLog.shared.clear(in: repository.url)
        _ = try await GitRuntime.run(GitStatus(directory: repository.url))
        await #expect(throws: GitExecutionError.self) {
            try await repository.git(["rev-parse", "--verify", "refs/heads/foldgit-missing"])
        }
        let entries = await GitCommandLog.shared.records(in: repository.url)
        let failures = CommandLogPresentation.filtered(entries, search: "", onlyFailures: true, includeReads: true)
        #expect(failures.count == 1)
        #expect(failures.first?.status == .failed)
        #expect(CommandLogPresentation.filtered(entries, search: "FOLDGIT-MISSING", onlyFailures: false, includeReads: true) == failures)
        #expect(CommandLogPresentation.filtered(entries, search: "", onlyFailures: false, includeReads: false) == failures)
        let text = CommandLogPresentation.transcript(failures)
        #expect(text.contains("refs/heads/foldgit-missing"))
        #expect(text.contains(repository.url.path))
        let standardError = try #require(failures.first?.standardError?.text)
        #expect(text.contains(standardError))
        #expect(!text.contains("status --porcelain"))
    }

    @Test func panelRendersAtMinimumWidthInBothAppearances() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        for scheme in [ColorScheme.light, .dark] {
            let root = CommandLogPanel(directory: repository.url, isPresented: .constant(true), selectedID: .constant(nil))
                .environment(\.colorScheme, scheme)
                .frame(width: 320, height: 600)
            let view = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 600),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(100))
            view.layoutSubtreeIfNeeded()
            let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            #expect(image.pixelsWide >= 320)
            #expect(image.pixelsHigh >= 600)
        }
    }
}

@MainActor
struct DiffDirectionAndStashTests {
    @Test func twoCommitsDiffFromOlderToNewerAndSwapReversesTheSides() async throws {
        let repository = try await TestRepository.create(commits: 2)
        defer { repository.remove() }
        let newer = try await repository.git(["rev-parse", "HEAD"])
        let older = try await repository.git(["rev-parse", "HEAD~1"])
        let ordered = try await CommitDiffView.chronological(newer, older, in: repository.url)
        #expect(ordered.0 == older && ordered.1 == newer)
        let reversed = try await CommitDiffView.chronological(older, newer, in: repository.url)
        #expect(reversed.0 == older && reversed.1 == newer)
        let raw = try await GitRuntime.run(RevisionDiffQuery(directory: repository.url,
            arguments: CommitDiffView.diffArguments(base: ordered.0, target: ordered.1)))
        #expect(raw.contains("+let value = 1"))
        let swapped = try await GitRuntime.run(RevisionDiffQuery(directory: repository.url,
            arguments: CommitDiffView.diffArguments(base: ordered.1, target: ordered.0)))
        #expect(swapped.contains("+let value = 0"))
    }

    @Test func workingTreeIsAlwaysTheNewerSide() async throws {
        let repository = try await TestRepository.create(commits: 1)
        defer { repository.remove() }
        try repository.write("example.swift", "let value = 9\n")
        let head = try await repository.git(["rev-parse", "HEAD"])
        let ordered = try await CommitDiffView.chronological(Log.notCommitted.id, head, in: repository.url)
        #expect(ordered.0 == head && ordered.1 == Log.notCommitted.id)
        let forward = try await GitRuntime.run(RevisionDiffQuery(directory: repository.url,
            arguments: CommitDiffView.diffArguments(base: head, target: Log.notCommitted.id)))
        #expect(forward.contains("+let value = 9"))
        let backward = try await GitRuntime.run(RevisionDiffQuery(directory: repository.url,
            arguments: CommitDiffView.diffArguments(base: Log.notCommitted.id, target: head)))
        #expect(backward.contains("-let value = 9"))
        #expect(CommitDiffView.shortRevision(head).count == 7)
        #expect(CommitDiffView.shortRevision("main") == "main")
    }

    @Test func largeAndGeneratedDiffsStartCollapsed() throws {
        #expect(DiffLoading.startsCollapsed("web/package-lock.json"))
        #expect(DiffLoading.startsCollapsed("Cargo.lock"))
        #expect(DiffLoading.startsCollapsed("assets/app.min.js"))
        #expect(!DiffLoading.startsCollapsed("Sources/App.swift"))
        let raw = """
        diff --git a/a.swift b/a.swift
        index 0000000..1111111 100644
        --- a/a.swift
        +++ b/a.swift
        @@ -1 +1 @@
        -a
        +b
        diff --git a/yarn.lock b/yarn.lock
        index 0000000..1111111 100644
        --- a/yarn.lock
        +++ b/yarn.lock
        @@ -1 +1 @@
        -a
        +b

        """
        let files = try Diff(raw: raw).fileDiffs
        let small = DiffLoading.expandable(files, rawLineCount: 14, prefersExpanded: true)
        #expect(small.map(\.isExpanded) == [true, false])
        let large = DiffLoading.expandable(files, rawLineCount: DiffLoading.largeDiffLineCount + 1, prefersExpanded: true)
        #expect(large.allSatisfy { !$0.isExpanded })
        #expect(DiffLoading.expandable(files, rawLineCount: 14, prefersExpanded: false).allSatisfy { !$0.isExpanded })
    }

    @Test func stashListIncludesBranchAndDateAndPopRemovesTheEntry() async throws {
        let repository = try await TestRepository.create(commits: 1)
        defer { repository.remove() }
        try repository.write("example.swift", "let value = 5\n")
        try await GitRuntime.run(GitStash(directory: repository.url, message: "work in progress"))
        let entries = try await GitRuntime.run(GitStashListDetails(directory: repository.url))
        #expect(entries.count == 1)
        #expect(entries.first?.index == 0)
        #expect(entries.first?.branch == "main")
        #expect(entries.first?.message == "work in progress")
        #expect(entries.first?.date != nil)
        try await GitRuntime.run(GitStashPop(directory: repository.url, index: 0))
        #expect(try await GitRuntime.run(GitStashListDetails(directory: repository.url)).isEmpty)
        let entry = StashListEntry(index: 2, subject: "WIP on feature/x: abc1234 Title", timestamp: "0")
        #expect(entry.branch == "feature/x" && entry.message == "abc1234 Title")
    }
}
