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
}
