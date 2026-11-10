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

    @Test func nonUTF8FilesStillDiffButTheirHunksAreNeverApplied() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        let url = repository.url.appendingPathComponent("latin1.txt")
        let lines = (1...30).map { "caf\u{E9} \($0)" }
        try #require(lines.joined(separator: "\n").appending("\n").data(using: .isoLatin1)).write(to: url)
        try await repository.commit("feat: add Latin-1 text")
        var changed = lines
        changed[1] = "first r\u{E9}sum\u{E9}"
        changed[27] = "second r\u{E9}sum\u{E9}"
        try #require(changed.joined(separator: "\n").appending("\n").data(using: .isoLatin1)).write(to: url)

        let diff = try Diff(raw: await GitRuntime.run(GitDiff(directory: repository.url)))
        let file = try #require(diff.fileDiffs.first)
        #expect(file.chunks.count == 2)
        #expect(file.chunks[1].raw.contains("\u{FFFD}"))
        let selection = diff.updateChunkStage(file.chunks[1], in: file, stage: true).indexSelection(staging: true)
        await #expect(throws: GitExecutionError.self) {
            try await IndexStaging.apply(selection, staging: true, in: repository.url)
        }
        await #expect(throws: GitExecutionError.self) {
            try await WorktreeDiscarding.discard(selection, in: repository.url)
        }
        #expect(try await WorktreeSnapshot.read(in: repository.url).staged.isEmpty)
        #expect(try Data(contentsOf: url) == changed.joined(separator: "\n").appending("\n").data(using: .isoLatin1))
    }

    @Test func userDiffConfigurationDoesNotChangeParsedPatches() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        try repository.write("list.txt", (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n")
        try await repository.commit("feat: add list")
        _ = try await repository.git(["config", "diff.noprefix", "true"])
        _ = try await repository.git(["config", "diff.external", "false"])
        try repository.write("list.txt", (1...30).map { $0 == 28 ? "changed" : "line \($0)" }.joined(separator: "\n") + "\n")

        let diff = try Diff(raw: await GitRuntime.run(GitDiff(directory: repository.url)))
        let file = try #require(diff.fileDiffs.first)
        #expect(file.toFilePath == "list.txt")
        try await IndexStaging.apply(diff.updateChunkStage(file.chunks[0], in: file, stage: true).indexSelection(staging: true),
                                     staging: true, in: repository.url)
        #expect(try await WorktreeSnapshot.read(in: repository.url).staged.contains("+changed"))
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

    @Test func discardRestoresWholeFileFromIndexAndKeepsStagedChanges() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        try repository.write("notes.txt", "one\n")
        try await repository.commit("feat: add notes")
        try repository.write("notes.txt", "two\n")
        _ = try await repository.git(["add", "notes.txt"])
        try repository.write("notes.txt", "three\n")
        let diff = try Diff(raw: await repository.git(["diff"]))
        try await WorktreeDiscarding.discard(diff.updateAll(stage: true).indexSelection(staging: true), in: repository.url)
        let snapshot = try await WorktreeSnapshot.read(in: repository.url)
        #expect(snapshot.unstaged.isEmpty)
        #expect(snapshot.staged.contains("+two"))
        #expect(try String(contentsOf: repository.url.appendingPathComponent("notes.txt"), encoding: .utf8) == "two\n")
    }

    @Test func discardSelectedHunkKeepsOtherHunks() async throws {
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
        try await WorktreeDiscarding.discard(diff.updateChunkStage(file.chunks[0], in: file, stage: true).indexSelection(staging: true),
                                             in: repository.url)
        let snapshot = try await WorktreeSnapshot.read(in: repository.url)
        #expect(!snapshot.unstaged.contains("+first change"))
        #expect(snapshot.unstaged.contains("+second change"))
        #expect(snapshot.staged.isEmpty)
    }

    @Test func discardCommandRestoresLiteralPathsWithoutClean() {
        let directory = URL(fileURLWithPath: "/tmp/repository")
        #expect(GitRestoreWorktree(directory: directory, paths: ["a b.txt", "-n"]).arguments
            == ["git", "--literal-pathspecs", "restore", "--worktree", "--", "a b.txt", "-n"])
    }

    @Test func untrackedTrashPathsStayInsideRepository() throws {
        let directory = URL(fileURLWithPath: "/tmp/repository")
        let urls = try WorktreeDiscarding.untrackedFileURLs(["new.txt", "dir/other.txt"], in: directory)
        #expect(urls.map(\.path) == ["/tmp/repository/new.txt", "/tmp/repository/dir/other.txt"])
        #expect(throws: (any Error).self) { try WorktreeDiscarding.untrackedFileURLs(["../outside.txt"], in: directory) }
        #expect(throws: (any Error).self) { try WorktreeDiscarding.untrackedFileURLs([""], in: directory) }
    }
}
