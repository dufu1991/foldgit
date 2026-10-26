import FoldGitTestSupport
import Foundation
import Testing
@testable import FoldGitCore

struct GitShowShortstatTests {
    @Test func statisticsComeFromTheRequestedCommit() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        try repository.write("second.swift", "let second = 2\n")
        try await repository.commit("feat: second file")
        let output = try await GitRuntime.run(GitShowShortstat(directory: repository.url, object: "HEAD"))
        #expect(output == "1 file changed, 1 insertion(+)")
    }
}
