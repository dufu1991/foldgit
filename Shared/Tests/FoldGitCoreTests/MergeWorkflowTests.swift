import FoldGitTestSupport
import Foundation
import Testing
@testable import FoldGitCore

struct MergeWorkflowTests {
    private func linked(_ repository: TestRepository) async throws -> URL {
        let url = repository.url.deletingLastPathComponent().appendingPathComponent(repository.url.lastPathComponent + "-feature")
        try await GitRuntime.run(GitWorktreeCommand(directory: repository.url,
            operation: .add(destination: url, branch: .new(name: "feature", startPoint: "HEAD"))))
        return url
    }
    private func git(_ args: [String], at directory: URL) async throws -> String {
        try await GitRuntime.run(arguments: ["git"] + args, currentDirectoryURL: directory).standardOutput.trimmingCharacters(in: .newlines)
    }
    private func write(_ text: String, at directory: URL, path: String = "example.swift") throws {
        try text.write(to: directory.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
    private func commit(_ directory: URL) async throws {
        _ = try await git(["add", "--all"], at: directory)
        _ = try await git(["commit", "-m", "change"], at: directory)
    }

    @Test func fastForwardCompletesAndCleanupDeletesOnlyMergedLocalBranch() async throws {
        let repo = try await TestRepository.create()
        let source = try await linked(repo)
        defer { repo.remove(); try? FileManager.default.removeItem(at: source) }
        try write("let feature = true\n", at: source, path: "feature.swift")
        try await commit(source)
        let plan = try await WorktreeCompletion.prepare(source: source, targetBranch: "main")
        #expect(plan.commitCount == 1)
        let result = try await WorktreeCompletion.merge(plan)
        guard case .merged = result else { Issue.record("Expected successful merge"); return }
        #expect(try await repo.git(["rev-parse", "main"]) == plan.sourceCommit)
        try await WorktreeCompletion.removeSource(plan)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try await repo.git(["branch", "--list", "feature"]).contains("feature"))
        try await WorktreeCompletion.deleteSourceBranch(plan)
        #expect(try await repo.git(["branch", "--list", "feature"]).isEmpty)
    }

    @Test func conflictsCanResumeAndCreateAMergeCommitWithAnEmptyResolvedDiff() async throws {
        let repo = try await TestRepository.create()
        let source = try await linked(repo)
        defer { repo.remove(); try? FileManager.default.removeItem(at: source) }
        try write("let feature = true\n", at: source)
        try await commit(source)
        try repo.write("example.swift", "let target = true\n")
        try await repo.commit("target change")
        let plan = try await WorktreeCompletion.prepare(source: source, targetBranch: "main")
        let result = try await WorktreeCompletion.merge(plan)
        guard case let .inProgress(state, _) = result else { Issue.record("Expected conflict"); return }
        #expect(state.conflicts.map(\.path) == ["example.swift"])
        #expect(try await GitMergeState.read(in: repo.url).isMerging)
        await #expect(throws: (any Error).self) { try await GitMergeWorkflow.continueMerge(in: repo.url) }
        await #expect(throws: (any Error).self) { try await GitMergeWorkflow.resolve("example.swift", choosing: .edited, in: repo.url) }
        try await GitMergeWorkflow.resolve("example.swift", choosing: .target, in: repo.url)
        #expect(try await repo.git(["diff", "--cached"]).isEmpty)
        #expect(try await GitMergeState.read(in: repo.url).canContinue)
        try await GitMergeWorkflow.continueMerge(in: repo.url)
        #expect(try await repo.git(["rev-list", "--parents", "-n", "1", "HEAD"]).split(separator: " ").count == 3)
        #expect(try await GitMergeState.read(in: repo.url).isMerging == false)
        try await WorktreeCompletion.requireIntegrated(plan)
        try await WorktreeCompletion.removeSource(plan)
    }

    @Test func abortRestoresTargetAndPreservesSourceCommits() async throws {
        let repo = try await TestRepository.create()
        let source = try await linked(repo)
        defer { repo.remove(); try? FileManager.default.removeItem(at: source) }
        try write("feature\n", at: source)
        try await commit(source)
        try repo.write("example.swift", "target\n")
        try await repo.commit("target change")
        let plan = try await WorktreeCompletion.prepare(source: source, targetBranch: "main")
        _ = try await WorktreeCompletion.merge(plan)
        try await GitMergeWorkflow.abort(in: repo.url)
        #expect(try await repo.git(["rev-parse", "HEAD"]) == plan.targetCommit)
        #expect(try await repo.git(["status", "--porcelain"]).isEmpty)
        #expect(try await git(["rev-parse", "HEAD"], at: source) == plan.sourceCommit)
        #expect(try await GitMergeState.read(in: repo.url).isMerging == false)
        await #expect(throws: (any Error).self) { try await WorktreeCompletion.removeSource(plan) }
    }

    @Test func manualAndDeletionResolutionsUseIndexStagesAndPreserveUnicodePaths() async throws {
        let repo = try await TestRepository.create()
        let path = "中文 conflict\tfile.swift"
        try repo.write(path, "base\n")
        try await repo.commit("base")
        let source = try await linked(repo)
        defer { repo.remove(); try? FileManager.default.removeItem(at: source) }
        try write("incoming\n", at: source, path: path)
        try await commit(source)
        _ = try await repo.git(["rm", "--", path])
        try await repo.commit("delete target")
        let plan = try await WorktreeCompletion.prepare(source: source, targetBranch: "main")
        _ = try await WorktreeCompletion.merge(plan)
        let conflict = try #require(try await GitMergeState.read(in: repo.url).conflicts.first)
        #expect(conflict.path == path)
        #expect(!conflict.targetExists && conflict.incomingExists)
        try await GitMergeWorkflow.resolve(path, choosing: .target, in: repo.url)
        #expect(!FileManager.default.fileExists(atPath: repo.url.appendingPathComponent(path).path))
        try await GitMergeWorkflow.continueMerge(in: repo.url)
        try await WorktreeCompletion.requireIntegrated(plan)
    }

    @Test func manualEditsCanBeStagedAndIncomingVersionCanBeSelected() async throws {
        let repo = try await TestRepository.create()
        let source = try await linked(repo)
        defer { repo.remove(); try? FileManager.default.removeItem(at: source) }
        for path in ["example.swift", "other.swift"] { try write("incoming\n", at: source, path: path) }
        try await commit(source)
        try repo.write("example.swift", "target\n")
        try repo.write("other.swift", "target\n")
        try await repo.commit("target")
        let plan = try await WorktreeCompletion.prepare(source: source, targetBranch: "main")
        _ = try await WorktreeCompletion.merge(plan)
        try write("resolved manually\n", at: repo.url)
        try await GitMergeWorkflow.resolve("example.swift", choosing: .edited, in: repo.url)
        try await GitMergeWorkflow.resolve("other.swift", choosing: .incoming, in: repo.url)
        try await GitMergeWorkflow.continueMerge(in: repo.url)
        #expect(try String(contentsOf: repo.url.appendingPathComponent("other.swift"), encoding: .utf8) == "incoming\n")
        #expect(try String(contentsOf: repo.url.appendingPathComponent("example.swift"), encoding: .utf8) == "resolved manually\n")
    }

    @Test func dirtyDirectoriesChangedCommitsAndUnmergedCleanupAreRejected() async throws {
        let repo = try await TestRepository.create()
        let source = try await linked(repo)
        defer { repo.remove(); try? FileManager.default.removeItem(at: source) }
        try write("pending\n", at: source, path: "untracked.swift")
        await #expect(throws: (any Error).self) { try await WorktreeCompletion.prepare(source: source, targetBranch: "main") }
        try await commit(source)
        try repo.write("untracked.swift", "target pending\n")
        await #expect(throws: (any Error).self) { try await WorktreeCompletion.prepare(source: source, targetBranch: "main") }
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("untracked.swift"))
        let plan = try await WorktreeCompletion.prepare(source: source, targetBranch: "main")
        await #expect(throws: (any Error).self) { try await WorktreeCompletion.removeSource(plan) }
        try write("new commit\n", at: source)
        try await commit(source)
        await #expect(throws: (any Error).self) { try await WorktreeCompletion.merge(plan) }
        await #expect(throws: (any Error).self) { try await WorktreeCompletion.removeSource(plan) }
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func uncheckedTargetSwitchesTheCleanMainDirectoryAndLockedCleanupIsRejected() async throws {
        let repo = try await TestRepository.create()
        let source = try await linked(repo)
        defer { repo.remove(); try? FileManager.default.removeItem(at: source) }
        _ = try await repo.git(["switch", "-c", "development"])
        try write("feature\n", at: source, path: "new.swift")
        try await commit(source)
        let plan = try await WorktreeCompletion.prepare(source: source, targetBranch: "main")
        #expect(plan.switchesTargetBranch)
        _ = try await WorktreeCompletion.merge(plan)
        #expect(try await repo.git(["branch", "--show-current"]) == "main")
        try await GitRuntime.run(GitWorktreeCommand(directory: repo.url, operation: .lock(source)))
        await #expect(throws: (any Error).self) { try await WorktreeCompletion.removeSource(plan) }
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func changedTargetRequiresNewPreviewAndNewSourceCommitsPreventCleanup() async throws {
        let repo = try await TestRepository.create()
        let source = try await linked(repo)
        defer { repo.remove(); try? FileManager.default.removeItem(at: source) }
        try write("feature\n", at: source, path: "feature.swift")
        try await commit(source)
        let outdated = try await WorktreeCompletion.prepare(source: source, targetBranch: "main")
        try repo.write("target.swift", "target\n")
        try await repo.commit("target changed")
        await #expect(throws: (any Error).self) { try await WorktreeCompletion.merge(outdated) }
        let plan = try await WorktreeCompletion.prepare(source: source, targetBranch: "main")
        _ = try await WorktreeCompletion.merge(plan)
        try write("new work\n", at: source, path: "new.swift")
        try await commit(source)
        await #expect(throws: (any Error).self) { try await WorktreeCompletion.removeSource(plan) }
        await #expect(throws: (any Error).self) { try await WorktreeCompletion.deleteSourceBranch(plan) }
        #expect(try await git(["log", "-1", "--format=%s"], at: source) == "change")
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func branchMergeOptionsCannotTurnCompletionIntoAnUncommittedSquash() async throws {
        let repo = try await TestRepository.create()
        let source = try await linked(repo)
        defer { repo.remove(); try? FileManager.default.removeItem(at: source) }
        try write("feature\n", at: source, path: "feature.swift")
        try await commit(source)
        try repo.write("target.swift", "target\n")
        try await repo.commit("target")
        try await repo.git(["config", "branch.main.mergeOptions", "--squash --no-commit"])
        let plan = try await WorktreeCompletion.prepare(source: source, targetBranch: "main")
        let result = try await WorktreeCompletion.merge(plan)
        guard case .merged = result else { Issue.record("Expected a committed merge"); return }
        try await WorktreeCompletion.requireIntegrated(plan)
        #expect(try await GitMergeState.read(in: repo.url).isMerging == false)
    }
}
