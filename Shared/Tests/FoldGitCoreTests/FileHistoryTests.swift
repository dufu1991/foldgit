import Foundation
import FoldGitTestSupport
import Testing
@testable import FoldGitCore

struct FileHistoryTests {
    @Test func repositoryFilesIncludeCleanAndUntrackedFilesAndRespectIgnores() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        try repository.write(".gitignore", "ignored/\n")
        try await repository.git(["add", "-f", ".gitignore"])
        try repository.write("ignored/generated.swift", "ignored")
        try repository.write("nested/中文 file.swift", "untracked")
        let files = try await GitRuntime.run(GitRepositoryFiles(directory: repository.url))
        #expect(files == [".gitignore", "example.swift", "nested/中文 file.swift"])
    }

    @Test func followsRenamesAcrossPagesAndDiffsEachHistoricalPath() async throws {
        let repository = try await TestRepository.create(commits: 0)
        defer { repository.remove() }
        #if os(Windows)
        let oldPath = "old/中文 [file].swift"
        #else
        let oldPath = "old/中文 [file]\n.swift"
        #endif
        let newPath = "new/-file.swift"
        try repository.write(oldPath, "let value = 1\n")
        try repository.write("unrelated.swift", "let other = 1\n")
        try await repository.commit("add files")
        let root = try await repository.git(["rev-parse", "HEAD"])
        try FileManager.default.createDirectory(at: repository.url.appendingPathComponent("new"), withIntermediateDirectories: true)
        try await repository.git(["mv", "--", oldPath, newPath])
        try await repository.commit("rename file")
        try repository.write(newPath, "let value = 2\n")
        try repository.write("unrelated.swift", "let other = 2\n")
        try await repository.commit("modify files")
        let head = try await repository.git(["rev-parse", "HEAD"])
        let all = try await history(repository, path: newPath, head: head)
        #expect(all.map(\.commit.title) == ["modify files", "rename file", "add files"])
        #expect(all[1].oldPath == oldPath)
        #expect(all[1].newPath == newPath)
        #expect(all[2].newPath == oldPath)
        #expect(all[2].commit.hash == root)
        for index in all.indices {
            let page = try await GitRuntime.run(GitFileHistory(directory: repository.url, path: newPath,
                revision: head, limit: index + 1))
            #expect(page == Array(all.prefix(index + 1)))
            let diff = try await GitRuntime.run(GitFileHistoryDiff(directory: repository.url, entry: all[index]))
            #expect(diff.fileDiffs.count == 1)
            #expect(diff.fileDiffs[0].toFilePath == all[index].newPath)
            #expect(!diff.raw.contains("unrelated.swift"))
        }
        let added = try await GitRuntime.run(GitFileHistoryDiff(directory: repository.url, entry: all[2]))
        #expect(added.raw.contains("+let value = 1"))
        let modified = try await GitRuntime.run(GitFileHistoryDiff(directory: repository.url, entry: all[0]))
        #expect(modified.raw.contains("-let value = 1"))
        #expect(modified.raw.contains("+let value = 2"))
    }

    @Test func literalPathsDoNotMatchOtherFilesAndDeletedFilesHaveHistory() async throws {
        let repository = try await TestRepository.create(commits: 0)
        defer { repository.remove() }
        try repository.write("[ab].txt", "original\n")
        try repository.write("a.txt", "other\n")
        try await repository.commit("add files")
        try repository.write("a.txt", "changed\n")
        try await repository.commit("change other")
        try await repository.git(["rm", "--", "[ab].txt"])
        try await repository.commit("delete file")
        let head = try await repository.git(["rev-parse", "HEAD"])
        let entries = try await history(repository, path: "[ab].txt", head: head)
        #expect(entries.map(\.commit.title) == ["delete file", "add files"])
        #expect(entries.first?.newPath == nil)
        let patch = try await GitRuntime.run(GitFileHistoryDiff(directory: repository.url, entry: entries[0]))
        #expect(patch.raw.contains("-original"))
        #expect(try await history(repository, path: "untracked.txt", head: head).isEmpty)
    }

    @Test func mergeDiffUsesActualFirstParentAndHistoryIsPinned() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        try await repository.git(["switch", "-c", "feature"])
        try repository.write("example.swift", "let value = 42\n")
        try await repository.commit("feature change")
        try await repository.git(["switch", "main"])
        try repository.write("other.txt", "main\n")
        try await repository.commit("main change")
        try await repository.git(["merge", "--no-ff", "feature", "-m", "merge feature"])
        let head = try await repository.git(["rev-parse", "HEAD"])
        let entries = try await history(repository, path: "example.swift", head: head)
        let merge = try #require(entries.first(where: { $0.commit.hash == head }))
        #expect(merge.commit.parentHashes.count == 2)
        let patch = try await GitRuntime.run(GitFileHistoryDiff(directory: repository.url, entry: merge))
        #expect(patch.raw.contains("+let value = 42"))
        #expect(!patch.raw.contains("other.txt"))
        try repository.write("example.swift", "let value = 99\n")
        try await repository.commit("later change")
        #expect(try await history(repository, path: "example.swift", head: head) == entries)
    }

    @Test func malformedHistoryFailsInsteadOfInventingPaths() throws {
        let query = GitFileHistory(directory: URL(fileURLWithPath: "/tmp"), path: "file", revision: "HEAD")
        #expect(try query.parse(for: "").isEmpty)
        #expect(throws: GitExecutionError.self) { try query.parse(for: "bad\0records") }
    }

    private func history(_ repository: TestRepository, path: String, head: String) async throws -> [FileHistoryEntry] {
        try await GitRuntime.run(GitFileHistory(directory: repository.url, path: path, revision: head))
    }
}
