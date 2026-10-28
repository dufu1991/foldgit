import FoldGitTestSupport
import Foundation
import Testing
@testable import FoldGitCore

struct GitLogTests {
    @Test func recordsPreserveUnicodeMessagesAndArbitrarySeparatorText() async throws {
        let repository = try await TestRepository.create(commits: 2)
        defer { repository.remove() }
        let message = "fix: 修复中文路径\n\nBody {separator-44cd166895ac93832525}\n{component-separator-44cd166895ac93832525}"
        try await repository.commit(message)
        try await repository.git(["tag", "v1.0.0"])
        let commits = try await GitRuntime.run(GitLog(directory: repository.url))
        #expect(commits.count == 3)
        #expect(commits[0].title == "fix: 修复中文路径")
        #expect(commits[0].body.contains("{separator-44cd166895ac93832525}"))
        #expect(commits[0].tags == ["v1.0.0"])
        #expect(commits[0].parentHashes == [commits[1].hash])
        #expect(commits.last?.parentHashes.isEmpty == true)
        let detail = try await GitRuntime.run(GitShow(directory: repository.url, object: commits[1].hash))
        #expect(detail.commit.hash == commits[1].hash)
        #expect(!detail.diff.fileDiffs.isEmpty)
    }

    @Test func emptyAndMalformedRecords() throws {
        let command = GitLog(directory: URL(fileURLWithPath: "/tmp"))
        #expect(try command.parse(for: "").isEmpty)
        #expect(throws: GitExecutionError.self) { try command.parse(for: "malformed") }
    }

    @Test func allHistoryIncludesBranchesAndTagsButExcludesStashInternals() async throws {
        let repository = try await TestRepository.create(commits: 2)
        defer { repository.remove() }
        try await repository.git(["switch", "-c", "other"])
        try await repository.commit("feat: another branch")
        let other = try await repository.git(["rev-parse", "HEAD"])
        try await repository.git(["switch", "main"])
        try await repository.git(["switch", "-c", "tagged"])
        try await repository.commit("feat: tagged history")
        let tagged = try await repository.git(["rev-parse", "HEAD"])
        try await repository.git(["tag", "-a", "v1", "-m", "release"])
        try await repository.git(["switch", "main"])
        try await repository.git(["branch", "-D", "tagged"])
        try repository.write("example.swift", "let draft = true\n")
        try await repository.git(["stash", "push", "-m", "hidden stash"])
        let stash = try await repository.git(["rev-parse", "refs/stash"])
        let snapshot = try await HistorySnapshot.read(in: repository.url)
        let current = try await GitRuntime.run(GitLog(directory: repository.url, revisionRange: snapshot.revisions(for: .currentBranch)))
        let all = try await GitRuntime.run(GitLog(directory: repository.url, revisionRange: snapshot.revisions(for: .allCommits)))
        #expect(current.count == 2)
        #expect(all.count == 4)
        #expect(snapshot.outsideCurrentBranch == [other, tagged])
        #expect(!all.contains { $0.id == stash })
        #expect(snapshot.incoming.isEmpty)
        #expect(snapshot.outgoing.isEmpty)
        let index = try await GitRuntime.run(GitCommitSearchIndex(directory: repository.url, revisions: snapshot.revisions(for: .allCommits)))
        #expect(try index.hashes(matching: "tagged history") == [tagged])
        let count = try await GitRuntime.run(GitRevListCount(directory: repository.url, revisions: snapshot.revisions(for: .allCommits)))
        #expect(count == all.count)
    }

    @Test func fetchedHistoryUsesConfiguredUpstreamAndHandlesDivergenceAndMerge() async throws {
        let remote = try await TestRepository.create(commits: 2)
        let local = try await TestRepository.create(commits: 0)
        defer { remote.remove(); local.remove() }
        try await local.git(["remote", "add", "team", remote.url.path])
        try await local.git(["fetch", "team"])
        try await local.git(["reset", "--hard", "team/main"])
        try await local.git(["branch", "-m", "local-main"])
        try await local.git(["branch", "--set-upstream-to=team/main"])
        let original = try await HistorySnapshot.read(in: local.url)
        #expect(original.incoming.isEmpty)
        try await remote.commit("feat: remote one")
        try await remote.commit("feat: remote two")
        try await remote.commit("feat: remote three")
        #expect(try await HistorySnapshot.read(in: local.url).incoming.isEmpty)
        try await local.git(["fetch", "team"])
        let behind = try await HistorySnapshot.read(in: local.url)
        #expect(behind.incoming.count == 3)
        #expect(behind.outgoing.isEmpty)
        #expect(behind.outsideCurrentBranch == behind.incomingHashes)
        let target = try #require(behind.incoming.first)
        let detail = try await GitRuntime.run(GitShow(directory: local.url, object: target))
        #expect(detail.commit.title == "feat: remote three")
        try await local.commit("feat: local change")
        let diverged = try await HistorySnapshot.read(in: local.url)
        #expect(diverged.incoming.count == 3)
        #expect(diverged.outgoing.count == 1)
        try await local.git(["merge", "--no-edit", "team/main"])
        let merged = try await HistorySnapshot.read(in: local.url)
        #expect(merged.incoming.isEmpty)
        #expect(merged.outsideCurrentBranch.isEmpty)
        #expect(merged.outgoing.count == 2)
        try await local.git(["switch", "--detach", target])
        let detached = try await HistorySnapshot.read(in: local.url)
        #expect(detached.headHash == target)
        #expect(detached.incoming.isEmpty)
        #expect(detached.outgoing.isEmpty)
    }

    @Test func emptyRepositoryHasNoHistoryTips() async throws {
        let repository = try await TestRepository.create(commits: 0)
        defer { repository.remove() }
        let snapshot = try await HistorySnapshot.read(in: repository.url)
        #expect(snapshot.headHash == nil)
        #expect(snapshot.revisions(for: .currentBranch).isEmpty)
        #expect(snapshot.revisions(for: .allCommits).isEmpty)
        #expect(snapshot.outsideCurrentBranch.isEmpty)
    }

}
