import Foundation
import Testing
import FoldGitCore
import FoldGitTestSupport

struct PortableCoreTests {
    @Test func reorderingSupportsNoncontiguousSelectionsInBothDirections() {
        #expect([0, 1, 2, 3, 4].movingElements(at: [0, 2], to: 5) == [1, 3, 4, 0, 2])
        #expect([0, 1, 2, 3, 4].movingElements(at: [2, 4], to: 0) == [2, 4, 0, 1, 3])
        #expect([0, 1, 2].movingElements(at: [], to: 2) == [0, 1, 2])
    }

    @Test func publicModelsAndGraphDoNotRequireTheNativeApplication() {
        let commit = Commit(hash: "root", parentHashes: [], author: "Developer", authorEmail: "dev@example.com",
                            authorDate: "2026-10-24T00:00:00Z", title: "feat: initial", body: "", branches: ["main"], tags: [])
        let positioned = CommitGraph().positionedCommits([commit])
        #expect(positioned.count == 1)
        #expect(positioned[0].column == 0)
        #expect(positioned[0].segments.isEmpty)
    }

    @Test func backgroundFetchUsesEnvironmentWithoutAUnixWrapper() {
        let fetch = GitFetch(directory: FileManager.default.temporaryDirectory, isBackground: true)
        #expect(fetch.arguments == ["git", "fetch"])
        #expect(fetch.environment == ["GIT_TERMINAL_PROMPT": "0", "GCM_INTERACTIVE": "Never"])
    }

    @Test func typedCommandsPassEnvironmentValuesToTheProcess() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        let output = try await GitRuntime.run(AuthorIdentityCommand(directory: repository.url))
        #expect(output.hasPrefix("FoldGit Portable <portable@example.com>"))
    }
}

private struct AuthorIdentityCommand: RepositoryCommand {
    var directory: URL
    let arguments = ["git", "var", "GIT_AUTHOR_IDENT"]
    let environment = ["GIT_AUTHOR_NAME": "FoldGit Portable", "GIT_AUTHOR_EMAIL": "portable@example.com"]
    func parse(for standardOutput: String) -> String { standardOutput }
}
