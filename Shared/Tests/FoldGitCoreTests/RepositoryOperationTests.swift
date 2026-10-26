import FoldGitTestSupport
import Foundation
import Testing
@testable import FoldGitCore

struct RepositoryOperationTests {
    @Test func wholeFileStagingAndUnstagingUsePathspecs() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        try repository.write("example.swift", "let value = 42\n")
        let diff = try Diff(raw: await repository.git(["diff"]))
        try await IndexStaging.apply(diff.updateAll(stage: true).indexSelection(staging: true), staging: true, in: repository.url)
        let staged = try await WorktreeSnapshot.read(in: repository.url)
        #expect(staged.staged.contains("+let value = 42"))
        #expect(staged.unstaged.isEmpty)
        let cached = try Diff(raw: staged.staged)
        try await IndexStaging.apply(cached.updateAll(stage: false).indexSelection(staging: false), staging: false, in: repository.url)
        let restored = try await WorktreeSnapshot.read(in: repository.url)
        #expect(restored.staged.isEmpty)
        #expect(restored.unstaged.contains("+let value = 42"))
    }

    @Test func selectedHunkIsStagedAndUnstagedAlone() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        let lines = (1...30).map { "line \($0)" }
        try repository.write("list.txt", lines.joined(separator: "\n") + "\n")
        try await repository.commit("feat: add list")
        var changed = lines
        changed[1] = "first change"
        changed[27] = "second change"
        try repository.write("list.txt", changed.joined(separator: "\n") + "\n")
        let diff = try Diff(raw: await repository.git(["diff"]))
        let file = try #require(diff.fileDiffs.first)
        #expect(file.chunks.count == 2)
        try await IndexStaging.apply(diff.updateChunkStage(file.chunks[1], in: file, stage: true).indexSelection(staging: true),
                                     staging: true, in: repository.url)
        let staged = try await WorktreeSnapshot.read(in: repository.url)
        #expect(staged.staged.contains("+second change"))
        #expect(!staged.staged.contains("+first change"))
        #expect(staged.unstaged.contains("+first change"))

        let cached = try Diff(raw: staged.staged)
        let cachedFile = try #require(cached.fileDiffs.first)
        try await IndexStaging.apply(cached.updateChunkStage(cachedFile.chunks[0], in: cachedFile, stage: false).indexSelection(staging: false),
                                     staging: false, in: repository.url)
        #expect(try await WorktreeSnapshot.read(in: repository.url).staged.isEmpty)
    }

    @Test func staleHunkIsRejectedInsteadOfStagingOtherChanges() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        let lines = (1...30).map { "line \($0)" }
        try repository.write("list.txt", lines.joined(separator: "\n") + "\n")
        try await repository.commit("feat: add list")
        var changed = lines
        changed[1] = "first change"
        changed[27] = "second change"
        try repository.write("list.txt", changed.joined(separator: "\n") + "\n")
        let diff = try Diff(raw: await repository.git(["diff"]))
        let file = try #require(diff.fileDiffs.first)
        // Another tool stages the file after FoldGit read the diff.
        try await repository.git(["add", "list.txt"])
        await #expect(throws: (any Error).self) {
            try await IndexStaging.apply(diff.updateChunkStage(file.chunks[0], in: file, stage: true).indexSelection(staging: true),
                                         staging: true, in: repository.url)
        }
    }
}
