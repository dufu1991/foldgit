import AppKit
import FoldGitCore
import FoldGitTestSupport
import Foundation
import Observation
import SwiftUI
import Testing
@testable import FoldGit

@MainActor
struct RemoteSyncStateTests {
    @Test(arguments: [false, true])
    func syncBadgeSurvivesSwiftUIToolbarUpdates(isPush: Bool) async throws {
        let state = PullToolbarTestState()
        let controller = NSHostingController(rootView: PullToolbarTestView(state: state, isPush: isPush))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))

        let identifier = isPush ? "repositoryPush" : "repositoryPull"
        let item = try #require(window.toolbar?.items.first { $0.itemIdentifier.rawValue == identifier })
        #expect(item.badge?.text == "8")
        for selection in 1...10 {
            state.selectedCommit = selection
            try await Task.sleep(for: .milliseconds(20))
            let current = try #require(window.toolbar?.items.first { $0.itemIdentifier.rawValue == identifier })
            #expect(current === item)
            #expect(current.badge?.text == "8")
        }

        state.count = 3
        try await Task.sleep(for: .milliseconds(50))
        #expect(item.badge?.text == "3")
        state.count = 0
        try await Task.sleep(for: .milliseconds(50))
        #expect(item.badge == nil)
    }

    @Test func fetchedBehindCountUpdatesAndClearsAfterCatchingUp() async throws {
        let remote = try await TestRepository.create()
        defer { remote.remove() }
        let local = try await TestRepository.create(commits: 0)
        defer { local.remove() }
        try await local.git(["remote", "add", "upstream", remote.url.path])
        try await local.git(["fetch", "upstream"])
        try await local.git(["reset", "--hard", "upstream/main"])
        try await local.git(["branch", "--set-upstream-to=upstream/main", "main"])

        let state = RemoteSyncState()
        state.folderURL = local.url
        state.branch = Branch(name: "main", isCurrent: true)
        await state.sync(fetchRemote: false)
        #expect(state.tracking?.behind == 0)
        #expect(!state.shouldPull)

        for index in 1...3 {
            try await remote.commit("feat: remote change \(index)")
        }
        await state.sync(fetchRemote: false)
        #expect(state.tracking?.behind == 0)
        await state.sync()
        #expect(state.syncError == nil)
        #expect(state.tracking?.behind == 3)
        #expect(state.tracking?.ahead == 0)
        #expect(state.shouldPull)

        try await local.git(["merge", "--ff-only", "upstream/main"])
        await state.sync(fetchRemote: false)
        #expect(state.tracking?.behind == 0)
        #expect(!state.shouldPull)
    }

    @Test func cachedSyncDoesNotFetchMissingRemote() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        try await repository.git(["remote", "add", "origin", repository.url.appendingPathComponent("missing.git").path])
        let state = RemoteSyncState()
        state.folderURL = repository.url
        state.branch = Branch(name: "main", isCurrent: true)
        await state.sync(fetchRemote: false)
        #expect(state.syncError == nil)
        #expect(state.shouldPush)
        #expect(state.tracking?.ahead == 1)
        await state.sync()
        #expect(state.syncError != nil)
        #expect(!state.shouldPush)
    }

    @Test func differentlyNamedTrackingBranchAndRemoteAreRespected() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        let remote = repository.url.appendingPathComponent("remote.git")
        try await repository.git(["init", "--bare", remote.path])
        try await repository.git(["remote", "add", "upstream", remote.path])
        try await repository.git(["push", "--set-upstream", "upstream", "HEAD:trunk"])
        let state = RemoteSyncState()
        state.folderURL = repository.url
        state.branch = Branch(name: "main", isCurrent: true)
        await state.sync(fetchRemote: false)
        #expect(state.tracking?.remote == "upstream")
        #expect(state.tracking?.remoteBranch == "trunk")
        #expect(!state.shouldPull)
        #expect(!state.shouldPush)
        for index in 1...3 {
            try await repository.commit("fix: local change \(index)")
        }
        await state.sync(fetchRemote: false)
        #expect(state.shouldPush)
        #expect(state.tracking?.ahead == 3)
        try await GitRuntime.run(GitPush(directory: repository.url, refspec: "HEAD:refs/heads/trunk", remote: "upstream"))
        await state.sync(fetchRemote: false)
        #expect(!state.shouldPush)
        #expect(state.tracking?.ahead == 0)
        try await repository.git(["branch", "--unset-upstream"])
        for index in 1...2 {
            try await repository.commit("feat: unpublished change \(index)")
        }
        await state.sync(fetchRemote: false)
        #expect(state.shouldPush)
        #expect(state.tracking?.upstream == nil)
        #expect(state.tracking?.ahead == 2)
        state.branch = Branch(name: "(HEAD detached at abc1234)", isCurrent: true)
        await state.sync(fetchRemote: false)
        #expect(!state.shouldPull && !state.shouldPush)
    }
}

@MainActor
@Observable private final class PullToolbarTestState {
    var selectedCommit = 0
    var count = 8
}

private struct PullToolbarTestView: View {
    let state: PullToolbarTestState
    let isPush: Bool

    var body: some View {
        Text("Commit \(state.selectedCommit)")
            .toolbar {
                if isPush {
                    ToolbarItem(id: "repositoryPush") {
                        PushToolbarButton(count: state.count, onPush: {})
                    }
                } else {
                    ToolbarItem(id: "repositoryPull") {
                        PullToolbarButton(count: state.count, toolTip: "Pull", onPull: {})
                    }
                }
            }
    }
}
