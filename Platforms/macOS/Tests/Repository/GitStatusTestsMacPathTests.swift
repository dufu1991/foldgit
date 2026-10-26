import FoldGitCore
import FoldGitTestSupport
import Foundation
import Testing

struct GitStatusTestsMacPathTests {
    @Test func preservesUnicodeSpacesTabsAndNewlinesInPaths() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        let paths = ["中文 文件.swift", "tab\tfile.txt", "line\nbreak.txt", "-option.txt"]
        for path in paths { try repository.write(path, "test\n") }
        let status = try await GitRuntime.run(GitStatus(directory: repository.url))
        #expect(Set(status.untrackedFiles) == Set(paths))
        try await GitRuntime.run(GitAddPathspec(directory: repository.url, pathspec: "-option.txt"))
        let staged = DiffStat(diff: try Diff(raw: await GitRuntime.run(GitDiff(directory: repository.url, cached: true))))
        #expect(staged.files == ["-option.txt"])
    }
}
