import FoldGitTestSupport
import Foundation
import Testing
@testable import FoldGitCore

struct WorktreeTests {
    @Test func porcelainPreservesUnicodeWhitespaceAndFlags() throws {
        let trees = try GitWorktree.parse("worktree /projects/main\0HEAD abc\0branch refs/heads/main\0\0worktree /projects/中文 work\nnext\0HEAD def\0detached\0locked review\nreason\0prunable missing directory\0\0")
        #expect(trees.count == 2)
        #expect(trees[0].isMain)
        #expect(trees[0].branch == "main")
        #expect(trees[1].url.path == "/projects/中文 work\nnext")
        #expect(trees[1].isDetached)
        #expect(trees[1].branch == nil)
        #expect(trees[1].lockReason == "review\nreason")
        #expect(trees[1].isPrunable)
        #expect(throws: (any Error).self) { try GitWorktree.parse("HEAD abc\0\0") }
    }

    @Test func bareRepositoryIsNotAMainWorkingDirectory() throws {
        let trees = try GitWorktree.parse("worktree /repo.git\0bare\0\0worktree /feature\0HEAD abc\0branch refs/heads/feature\0locked\0\0")
        #expect(trees[0].isBare)
        #expect(!trees[0].isMain)
        #expect(!trees[1].isMain)
        #expect(trees[1].isLocked)
    }

    @Test func createCommitMoveLockAndRemovePreserveMainChangesAndBranch() async throws {
        let repository = try await TestRepository.create()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoldGit-worktrees-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { repository.remove(); try? FileManager.default.removeItem(at: root) }
        let linked = root.appendingPathComponent("中文 worktree")
        let moved = root.appendingPathComponent("moved worktree")
        try repository.write("example.swift", "let mainChanges = true\n")
        let run: (WorktreeOperation) async throws -> Void = { operation in
            try await GitRuntime.run(GitWorktreeCommand(directory: repository.url, operation: operation))
        }
        try await run(.add(destination: linked, branch: .new(name: "feature/worktree", startPoint: "HEAD")))
        var trees = try await GitRuntime.run(GitWorktreeList(directory: linked))
        #expect(trees.count == 2)
        #expect(trees[1].branch == "feature/worktree")
        #expect(try String(contentsOf: repository.url.appendingPathComponent("example.swift"), encoding: .utf8) == "let mainChanges = true\n")
        #expect(try String(contentsOf: linked.appendingPathComponent("example.swift"), encoding: .utf8) == "let value = 0\n")
        try "let feature = true\n".write(to: linked.appendingPathComponent("feature.swift"), atomically: true, encoding: .utf8)
        await #expect(throws: (any Error).self) { try await run(.remove(linked)) }
        _ = try await GitRuntime.run(arguments: ["git", "add", "--all"], currentDirectoryURL: linked)
        _ = try await GitRuntime.run(arguments: ["git", "commit", "-m", "feat: worktree"], currentDirectoryURL: linked)
        #expect(try await repository.git(["log", "feature/worktree", "-1", "--format=%s"]) == "feat: worktree")
        #expect(try await repository.git(["log", "main", "-1", "--format=%s"]) == "feat: commit 0")
        try await run(.lock(linked))
        await #expect(throws: (any Error).self) { try await run(.remove(linked)) }
        await #expect(throws: (any Error).self) { try await run(.move(linked, destination: moved)) }
        try await run(.unlock(linked))
        try await run(.move(linked, destination: moved))
        trees = try await GitRuntime.run(GitWorktreeList(directory: moved))
        #expect(trees[1].id == moved.resolvingSymlinksInPath())
        try await run(.remove(moved))
        #expect(!FileManager.default.fileExists(atPath: moved.path))
        #expect(try await repository.git(["branch", "--list", "feature/worktree"]).contains("feature/worktree"))
        await #expect(throws: (any Error).self) { try await run(.remove(repository.url)) }
    }

    @Test func existingAndDetachedTreesRespectOccupancyAndPruneMissingEntries() async throws {
        let repository = try await TestRepository.create()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoldGit-worktrees-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { repository.remove(); try? FileManager.default.removeItem(at: root) }
        let linked = root.appendingPathComponent("existing")
        let detached = root.appendingPathComponent("detached")
        let run: (WorktreeOperation) async throws -> Void = { operation in
            try await GitRuntime.run(GitWorktreeCommand(directory: repository.url, operation: operation))
        }
        try await repository.git(["branch", "existing"])
        try await run(.add(destination: linked, branch: .existing("existing")))
        await #expect(throws: (any Error).self) {
            try await run(.add(destination: root.appendingPathComponent("duplicate"), branch: .existing("existing")))
        }
        await #expect(throws: (any Error).self) {
            try await GitRuntime.run(GitSwitch(directory: repository.url, branchName: "existing"))
        }
        try await run(.add(destination: detached, branch: .detached(startPoint: "HEAD")))
        let trees = try await GitRuntime.run(GitWorktreeList(directory: repository.url))
        #expect(trees.first { $0.url.lastPathComponent == "detached" }?.isDetached == true)
        try FileManager.default.removeItem(at: linked)
        try await run(.prune)
        #expect(try await GitRuntime.run(GitWorktreeList(directory: repository.url)).count == 2)
    }
}
