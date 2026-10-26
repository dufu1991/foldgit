import Foundation
import Testing
import FoldGitCore
import FoldGitTestSupport

struct CommitSearchTests {
    @Test func matchesAuthorEmailMessageAndBodyAsLiteralUnicodeText() async throws {
        let repository = try await TestRepository.create(commits: 3)
        defer { repository.remove() }
        try await repository.git(["-c", "user.name=李明", "-c", "user.email=ming@example.com", "commit", "--allow-empty", "-m", "fix: 修复中文搜索", "-m", "日本語と한국어。literal [a].* --author=x"])
        let index = try await GitRuntime.run(GitCommitSearchIndex(directory: repository.url))
        let latest = try #require(index.entries.first?.hash)
        for text in ["李明", "MING@EXAMPLE.COM", "修复中文", "日本語", "한국어", "[a].*", "--author=x"] {
            #expect(try index.hashes(matching: text) == [latest])
        }
        #expect(try index.hashes(matching: "missing author") == [])
        #expect(try index.hashes(matching: "commit 0").count == 1)
        #expect(try index.hashes(matching: "example.com").count == 4)
    }

    @Test func indexUsesCurrentHistoryAndPagesPreserveItsOrder() async throws {
        let repository = try await TestRepository.create(commits: 5)
        defer { repository.remove() }
        try await repository.git(["switch", "-c", "unrelated"])
        try await repository.commit("feat: other branch only")
        try await repository.git(["switch", "main"])
        let index = try await GitRuntime.run(GitCommitSearchIndex(directory: repository.url))
        #expect(try index.hashes(matching: "other branch").isEmpty)
        let hashes = try index.hashes(matching: "commit")
        #expect(hashes.count == 5)
        let first = try await GitRuntime.run(GitCommitSearchPage(directory: repository.url, hashes: Array(hashes.prefix(2))))
        let next = try await GitRuntime.run(GitCommitSearchPage(directory: repository.url, hashes: Array(hashes.dropFirst(2).prefix(2))))
        #expect(first.map(\.hash) == Array(hashes.prefix(2)))
        #expect(next.map(\.hash) == Array(hashes.dropFirst(2).prefix(2)))
        #expect(first.map(\.title) == ["feat: commit 4", "feat: commit 3"])
    }
}
