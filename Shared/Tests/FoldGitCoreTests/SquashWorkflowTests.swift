import FoldGitCore
import FoldGitTestSupport
import Foundation
import Testing

struct SquashWorkflowTests {
    private func history(_ repository: TestRepository) async throws -> [Commit] {
        try await GitRuntime.run(GitLog(directory: repository.url, revisionRange: ["HEAD"]))
    }

    @Test func middleRangePreservesTreesMessagesAndOtherReferences() async throws {
        let repository = try await TestRepository.create(commits: 5)
        defer { repository.remove() }
        let before = try await history(repository)
        try await repository.git(["branch", "keep", before[2].hash])
        try await repository.git(["tag", "keep", before[3].hash])
        try await repository.git(["config", "rebase.updateRefs", "true"])
        let tree = try await repository.git(["rev-parse", "HEAD^{tree}"])
        let plan = try await GitSquash.prepare(in: repository.url, hashes: [before[2].hash, before[3].hash])
        #expect(plan.message == before[3].title + " | " + before[2].title)
        #expect(plan.followingCount == 2)
        let message = "feat: 压缩提交\n正文 $() `literal` 'quoted'\nCo-authored-by: Other <other@example.com>"
        let hash = try await GitSquash.execute(plan, message: message, in: repository.url)
        let after = try await history(repository)
        #expect(after.count == 4)
        #expect(after[2].hash == hash)
        #expect(try await repository.git(["show", "-s", "--format=%B", hash]) == message)
        #expect(after[0].rawBody == before[0].rawBody)
        #expect(after[1].rawBody == before[1].rawBody)
        #expect(after[3].hash == before[4].hash)
        #expect(try await repository.git(["rev-parse", "HEAD^{tree}"]) == tree)
        #expect(try await repository.git(["rev-parse", "refs/heads/keep"]) == before[2].hash)
        #expect(try await repository.git(["rev-parse", "refs/tags/keep"]) == before[3].hash)
        #expect(try await repository.git(["status", "--porcelain"]) == "")
        #expect(try await repository.git(["for-each-ref", "refs/foldgit/squash-backups"]) == "")
    }

    @Test func lockedIndexBlocksPreparationAndExecutionWithoutChangingHistory() async throws {
        let repository = try await TestRepository.create(commits: 3)
        defer { repository.remove() }
        let before = try await history(repository)
        let hashes = Set(before.prefix(2).map(\.hash))
        let plan = try await GitSquash.prepare(in: repository.url, hashes: hashes)
        let gitDirectory = try await repository.git(["rev-parse", "--absolute-git-dir"])
        let lock = URL(fileURLWithPath: gitDirectory).appendingPathComponent("index.lock")
        try Data().write(to: lock)
        for execute in [false, true] {
            do {
                if execute {
                    _ = try await GitSquash.execute(plan, message: plan.message, in: repository.url)
                } else {
                    _ = try await GitSquash.prepare(in: repository.url, hashes: hashes)
                }
                Issue.record("A locked index must block squashing")
            } catch {
                #expect(error.localizedDescription.contains("index is locked"))
            }
        }
        #expect(FileManager.default.fileExists(atPath: lock.path))
        #expect(try await repository.git(["rev-parse", "HEAD"]) == plan.head)
        #expect(try await repository.git(["for-each-ref", "refs/foldgit/squash-backups"]) == "")
        try FileManager.default.removeItem(at: lock)
        _ = try await GitSquash.execute(plan, message: plan.message, in: repository.url)
        #expect(try await history(repository).count == before.count - 1)
    }

    @Test func rootRangeAndThreeMessages() async throws {
        let repository = try await TestRepository.create(commits: 3)
        defer { repository.remove() }
        let before = try await history(repository)
        let plan = try await GitSquash.prepare(in: repository.url, hashes: Set(before.map(\.hash)))
        #expect(plan.message == before.reversed().map(\.title).joined(separator: " | "))
        _ = try await GitSquash.execute(plan, message: "one\ntwo\nthree", in: repository.url)
        let after = try await history(repository)
        #expect(after.count == 1)
        #expect(after[0].parentHashes.isEmpty)
        #expect(after[0].title == "one")
        #expect(after[0].body == "two\nthree")
        #expect(after[0].rawBody == "one\ntwo\nthree")
        let detail = try await GitRuntime.run(GitShow(directory: repository.url, object: "HEAD"))
        #expect(detail.commit.rawBody == "one\ntwo\nthree")
        #expect(detail.commit.title == "one")
        #expect(detail.commit.body == "two\nthree")
        #expect(try await repository.git(["show", "-s", "--format=%B", "HEAD"]) == "one\ntwo\nthree")
    }

    @Test func nonconsecutiveDirtyDetachedAndMergeHistoriesAreRejected() async throws {
        let repository = try await TestRepository.create(commits: 4)
        defer { repository.remove() }
        let commits = try await history(repository)
        await #expect(throws: (any Error).self) {
            try await GitSquash.prepare(in: repository.url, hashes: [commits[0].hash, commits[2].hash])
        }
        try repository.write("untracked.txt", "keep me")
        await #expect(throws: (any Error).self) {
            try await GitSquash.prepare(in: repository.url, hashes: [commits[0].hash, commits[1].hash])
        }
        try FileManager.default.removeItem(at: repository.url.appendingPathComponent("untracked.txt"))
        try await repository.git(["checkout", "--detach"])
        await #expect(throws: (any Error).self) {
            try await GitSquash.prepare(in: repository.url, hashes: [commits[0].hash, commits[1].hash])
        }
        try await repository.git(["switch", "main"])
        try await repository.git(["switch", "-c", "side", "HEAD~2"])
        try repository.write("side.txt", "side")
        try await repository.commit("side")
        let side = try await repository.git(["rev-parse", "HEAD"])
        try await repository.git(["switch", "main"])
        await #expect(throws: (any Error).self) {
            try await GitSquash.prepare(in: repository.url, hashes: [commits[0].hash, side])
        }
        try await repository.git(["merge", "--no-ff", "side", "-m", "merge side"])
        let merged = try await history(repository)
        await #expect(throws: (any Error).self) {
            try await GitSquash.prepare(in: repository.url, hashes: [merged[0].hash, commits[0].hash])
        }
    }

    @Test func publishedOtherBranchAndTagAreRejectedWithoutUpstream() async throws {
        let repository = try await TestRepository.create(commits: 4)
        let remote = try await TestRepository.create()
        defer {
            repository.remove()
            remote.remove()
        }
        try await remote.git(["config", "receive.denyCurrentBranch", "ignore"])
        try await repository.git(["remote", "add", "elsewhere", remote.url.path])
        try await repository.git([
            "config", "remote.elsewhere.fetch", "+refs/heads/missing:refs/remotes/elsewhere/missing",
        ])
        let commits = try await history(repository)
        // A published descendant also makes the selected ancestors published.
        try await repository.git(["push", "elsewhere", "HEAD:refs/heads/published"])
        await #expect(throws: (any Error).self) {
            try await GitSquash.prepare(in: repository.url, hashes: [commits[2].hash, commits[1].hash])
        }
        try await repository.git(["push", "elsewhere", ":refs/heads/published"])
        try await repository.git(["push", "elsewhere", "HEAD:refs/tags/published"])
        await #expect(throws: (any Error).self) {
            try await GitSquash.prepare(in: repository.url, hashes: [commits[0].hash, commits[1].hash])
        }
        #expect(try await repository.git(["for-each-ref", "refs/foldgit/squash-check"]) == "")
    }

    @Test func unpublishedCommitsCanBeSquashedAndPublicationIsRechecked() async throws {
        let repository = try await TestRepository.create()
        let remote = try await TestRepository.create()
        defer {
            repository.remove()
            remote.remove()
        }
        try await remote.git(["config", "receive.denyCurrentBranch", "ignore"])
        try await repository.git(["remote", "add", "origin", remote.url.path])
        try await repository.git(["push", "origin", "HEAD:refs/heads/topic"])
        try await repository.commit("one\n\nbody")
        try await repository.commit("two")
        let commits = try await history(repository)
        let plan = try await GitSquash.prepare(in: repository.url, hashes: [commits[0].hash, commits[1].hash])
        #expect(plan.message == "one | two")
        try await repository.git(["push", "origin", "HEAD:refs/heads/topic"])
        await #expect(throws: (any Error).self) {
            try await GitSquash.execute(plan, message: plan.message, in: repository.url)
        }
        #expect(try await repository.git(["rev-parse", "HEAD"]) == plan.head)
    }

    @Test func stalePlanAndUnavailableRemoteFailWithoutChangingHistory() async throws {
        let repository = try await TestRepository.create(commits: 3)
        defer { repository.remove() }
        let commits = try await history(repository)
        let plan = try await GitSquash.prepare(in: repository.url, hashes: [commits[0].hash, commits[1].hash])
        try await repository.commit("agent change")
        let head = try await repository.git(["rev-parse", "HEAD"])
        await #expect(throws: (any Error).self) {
            try await GitSquash.execute(plan, message: "squashed", in: repository.url)
        }
        try await repository.git([
            "remote", "add", "offline", repository.url.appendingPathComponent("missing.git").path,
        ])
        await #expect(throws: (any Error).self) {
            try await GitSquash.prepare(in: repository.url, hashes: [commits[0].hash, commits[1].hash])
        }
        #expect(try await repository.git(["rev-parse", "HEAD"]) == head)
    }

    @Test func failedHookRestoresOriginalHistory() async throws {
        let repository = try await TestRepository.create(commits: 3)
        defer { repository.remove() }
        let commits = try await history(repository)
        let plan = try await GitSquash.prepare(in: repository.url, hashes: [commits[0].hash, commits[1].hash])
        let hook = repository.url.appendingPathComponent(".git/hooks/pre-rebase")
        try "#!/bin/sh\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        await #expect(throws: (any Error).self) {
            try await GitSquash.execute(plan, message: "combined", in: repository.url)
        }
        #expect(try await repository.git(["rev-parse", "HEAD"]) == plan.head)
        #expect(
            !FileManager.default.fileExists(atPath: repository.url.appendingPathComponent(".git/rebase-merge").path))
        #expect(
            !FileManager.default.fileExists(
                atPath: repository.url.appendingPathComponent(".git/foldgit-squash.json").path))
    }
}
