import FoldGitCore
import FoldGitTestSupport
import Foundation
import Testing

struct RepositoryOperationTestsMacPathTests {
    @Test func fileDiffsPreserveQuotedAndUnicodePaths() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        let paths = ["中文 文件.swift", "tab\tfile.swift", "line\nbreak.swift"]
        for path in paths { try repository.write(path, "let value = 1\n") }
        try await repository.commit("feat: Unicode files")
        for path in paths { try repository.write(path, "let value = 2\n") }
        let snapshot = try await WorktreeSnapshot.read(in: repository.url)
        let diff = try Diff(raw: snapshot.unstaged)
        #expect(Set(diff.fileDiffs.map(\.toFilePath)) == Set(paths))
        #expect(Set(DiffStat(diff: diff).files) == Set(paths))
    }
}
