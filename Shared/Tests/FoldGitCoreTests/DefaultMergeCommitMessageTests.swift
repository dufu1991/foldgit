import FoldGitTestSupport
import Foundation
import Testing
@testable import FoldGitCore

struct DefaultMergeCommitMessageTests {
    @Test func readsMergeMessageFromTheRepositoryGitDirectory() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        let path = try await GitRuntime.run(GitRevParse(directory: repository.url, gitPath: "MERGE_MSG"))
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : repository.url.appendingPathComponent(path)
        try "Merge branch 'feature'\n\n# Conflicts:\n#\texample.swift\n".write(to: url, atomically: true, encoding: .utf8)
        let message = try await DefaultMergeCommitMessage(directory: repository.url).get()
        #expect(message == "Merge branch 'feature'\n\n# Conflicts:\n#\texample.swift")
    }
}
