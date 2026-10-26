import FoldGitTestSupport
import Foundation
import Testing
@testable import FoldGitCore

struct GitRevParseTests {
    @Test func resolvesGitPathWithoutExternalFixtures() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        let path = try await GitRuntime.run(GitRevParse(directory: repository.url, gitPath: "MERGE_MSG"))
        #expect(path.hasSuffix("MERGE_MSG"))
    }
}
