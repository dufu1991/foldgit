import FoldGitTestSupport
import Foundation
import Testing
@testable import FoldGitCore

struct WorktreeStatusTests {
    @Test func porcelainV2CountsEachKindAndSkipsRenameSources() throws {
        let output = [
            "# branch.oid 1234abcd", "# branch.head feature/状态", "# branch.upstream origin/feature", "# branch.ab +2 -3",
            "1 M. N... 100644 100644 100644 aaa bbb staged.swift",
            "1 .M N... 100644 100644 100644 aaa bbb unstaged.swift",
            "1 MM N... 100644 100644 100644 aaa bbb both.swift",
            "2 R. N... 100644 100644 100644 aaa bbb R100 new name.swift", "old name.swift",
            "u UU N... 100644 100644 100644 100644 aaa bbb ccc conflict.swift",
            "? 中文 untracked.txt",
            "! ignored.log",
        ].joined(separator: "\0") + "\0"
        let status = try GitWorkingTreeStatus.parse(output)
        #expect(status.head == "1234abcd")
        #expect(status.branch == "feature/状态")
        #expect(status.upstream == UpstreamDivergence(ahead: 2, behind: 3))
        #expect(status.changes == WorktreeChangeCounts(staged: 3, unstaged: 2, untracked: 1, conflicted: 1, files: 6))
    }

    @Test func porcelainV2HandlesUnbornDetachedAndCleanTrees() throws {
        let unborn = try GitWorkingTreeStatus.parse("# branch.oid (initial)\0# branch.head main\0")
        #expect(unborn.head == nil)
        #expect(unborn.branch == "main")
        #expect(unborn.changes.isClean)
        let detached = try GitWorkingTreeStatus.parse("# branch.oid abc\0# branch.head (detached)\0")
        #expect(detached.branch == nil)
        #expect(detached.upstream == nil)
        #expect(throws: (any Error).self) { try GitWorkingTreeStatus.parse("# branch.ab nonsense\0") }
        #expect(throws: (any Error).self) { try GitWorkingTreeStatus.parse("X unknown\0") }
    }

    @Test func statusReadsNeverTakeOptionalLocks() {
        let url = URL(fileURLWithPath: "/repo")
        #expect(GitWorkingTreeStatusQuery(directory: url).arguments.starts(with: ["git", "--no-optional-locks", "status"]))
        #expect(GitIgnoredEntriesQuery(directory: url).arguments.starts(with: ["git", "--no-optional-locks", "status"]))
    }

    @Test func ignoredEntriesCollapseToTopLevelPaths() {
        let query = GitIgnoredEntriesQuery(directory: URL(fileURLWithPath: "/repo"))
        let entries = query.parse(for: "!! node_modules/\0!! .env.local\0?? new.txt\0!! build/cache/a\0!! build/b\0")
        #expect(entries == ["node_modules", ".env.local", "build"])
    }

    @Test func integrationRecognizesFastForwardSquashAndUnmergedBranches() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let fastForward = try await fixture.worktree("ff", commits: ["ff.txt"])
        let squashed = try await fixture.worktree("squash", commits: ["a.txt", "b.txt"])
        let pending = try await fixture.worktree("pending", commits: ["pending.txt"])
        try await fixture.repository.git(["merge", "--ff-only", "ff"])
        try await fixture.repository.git(["merge", "--squash", "squash"])
        try await fixture.repository.git(["commit", "-m", "feat: squash"])

        let trunk = try #require(try await TrunkReference.resolve(in: fixture.repository.url))
        #expect(trunk == TrunkReference(local: "refs/heads/main", remote: nil))
        let ff = try await WorktreeStatus.read(fastForward, trunk: trunk)
        #expect(ff.trunk?.integration == .ancestor)
        #expect(ff.trunk?.ahead == 0)
        #expect(ff.canBeCleanedUp)
        let squash = try await WorktreeStatus.read(squashed, trunk: trunk)
        #expect(squash.trunk?.integration == .contentMerged)
        #expect(squash.trunk?.ahead == 2)
        let open = try await WorktreeStatus.read(pending, trunk: trunk)
        #expect(open.trunk?.integration == .notIntegrated)
        #expect(open.trunk == TrunkComparison(reference: "main", ahead: 1, behind: 2, integration: .notIntegrated))
        #expect(!open.canBeCleanedUp)
    }

    @Test func remoteTrunkCountsAsIntegratedBeforeTheLocalTrunkCatchesUp() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let feature = try await fixture.worktree("hosted", commits: ["hosted.txt"])
        // A hosted squash merge exists only on origin/main until the next pull.
        try await fixture.repository.git(["switch", "--detach", "main"])
        try await fixture.repository.git(["merge", "--squash", "hosted"])
        try await fixture.repository.git(["commit", "-m", "feat: hosted (#1)"])
        try await fixture.repository.git(["update-ref", "refs/remotes/origin/main", "HEAD"])
        try await fixture.repository.git(["switch", "main"])
        try await fixture.repository.git(["remote", "add", "origin", "https://example.com/repo.git"])
        try await fixture.repository.git(["config", "branch.main.remote", "origin"])
        try await fixture.repository.git(["config", "branch.main.merge", "refs/heads/main"])
        try await fixture.repository.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])

        let trunk = try #require(try await TrunkReference.resolve(in: feature))
        #expect(trunk == TrunkReference(local: "refs/heads/main", remote: "refs/remotes/origin/main"))
        #expect(trunk.displayName == "origin/main")
        let status = try await WorktreeStatus.read(feature, trunk: trunk)
        #expect(status.trunk?.reference == "origin/main")
        #expect(status.trunk?.integration == .contentMerged)
    }

    @Test func trunkResolutionPrefersExplicitThenOriginHeadThenConventionalNames() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        try await fixture.repository.git(["branch", "develop"])
        #expect(try await TrunkReference.resolve(in: fixture.repository.url, preferred: "develop")?.local == "refs/heads/develop")
        #expect(try await TrunkReference.resolve(in: fixture.repository.url, preferred: "missing")?.local == "refs/heads/main")
        try await fixture.repository.git(["update-ref", "refs/remotes/origin/develop", "develop"])
        try await fixture.repository.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/develop"])
        #expect(try await TrunkReference.resolve(in: fixture.repository.url)
            == TrunkReference(local: "refs/heads/develop", remote: "refs/remotes/origin/develop"))
        try await fixture.repository.git(["branch", "-m", "main", "trunk"])
        try await fixture.repository.git(["symbolic-ref", "--delete", "refs/remotes/origin/HEAD"])
        try await fixture.repository.git(["update-ref", "-d", "refs/remotes/origin/develop"])
        #expect(try await TrunkReference.resolve(in: fixture.repository.url, mainWorktreeBranch: "trunk")?.local == "refs/heads/trunk")
        #expect(try await TrunkReference.resolve(in: fixture.repository.url) == nil)
    }

    @Test func comparisonCacheSkipsRecomputingUntilTheTrunkMoves() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let feature = try await fixture.worktree("cached", commits: ["cached.txt"])
        let trunk = try #require(try await TrunkReference.resolve(in: feature))
        let cache = TrunkComparisonCache()
        let first = try await WorktreeStatus.read(feature, trunk: trunk, cache: cache)
        #expect(first.trunk?.integration == .notIntegrated)
        try await fixture.repository.git(["merge", "--ff-only", "cached"])
        let second = try await WorktreeStatus.read(feature, trunk: trunk, cache: cache)
        #expect(second.trunk?.integration == .ancestor)
    }

    @Test func pendingOperationsAreReported() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let feature = try await fixture.worktree("conflict", commits: [])
        try fixture.write(in: feature, "example.swift", "let value = 1\n")
        try await fixture.git(in: feature, ["commit", "-am", "feat: feature side"])
        try fixture.repository.write("example.swift", "let value = 2\n")
        try await fixture.repository.commit("feat: main side")
        await #expect(throws: (any Error).self) { try await fixture.git(in: feature, ["merge", "main"]) }
        let trunk = try await TrunkReference.resolve(in: feature)
        let status = try await WorktreeStatus.read(feature, trunk: trunk)
        #expect(status.operation == .merge)
        #expect(status.changes.conflicted == 1)
        #expect(!status.isClean)
    }
}

struct WorktreeCleanupTests {
    @Test func candidatesIncludeOnlyCleanIntegratedUnlockedLinkedWorktrees() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let merged = try await fixture.worktree("merged", commits: ["merged.txt"])
        let squashed = try await fixture.worktree("squashed", commits: ["squashed.txt"])
        let dirty = try await fixture.worktree("dirty", commits: ["dirty.txt"])
        let untracked = try await fixture.worktree("untracked", commits: ["untracked.txt"])
        let locked = try await fixture.worktree("locked", commits: ["locked.txt"])
        _ = try await fixture.worktree("open", commits: ["open.txt"])
        let secrets = try await fixture.worktree("secrets", commits: ["secrets.txt"])
        for branch in ["merged", "dirty", "untracked", "locked", "secrets"] {
            try await fixture.repository.git(["merge", "--no-edit", branch])
        }
        try await fixture.repository.git(["merge", "--squash", "squashed"])
        try await fixture.repository.git(["commit", "-m", "feat: squashed"])
        try fixture.write(in: dirty, "dirty.txt", "edited\n")
        try fixture.write(in: untracked, "new.txt", "new\n")
        try await fixture.repository.git(["worktree", "lock", locked.path])
        try fixture.write(in: secrets, ".env", "TOKEN=1\n")
        try fixture.write(in: secrets, "node_modules/a/index.js", "\n")
        try fixture.write(in: merged, "node_modules/a/index.js", "\n")

        let candidates = try await WorktreeCleanup.candidates(in: fixture.repository.url)
        #expect(Set(candidates.map(\.tree.branch)) == ["merged", "squashed", "secrets"])
        let byBranch = Dictionary(uniqueKeysWithValues: candidates.map { ($0.tree.branch ?? "", $0) })
        #expect(byBranch["merged"]?.trunk.integration == .ancestor)
        #expect(byBranch["squashed"]?.trunk.integration == .contentMerged)
        #expect(byBranch["merged"]?.notableIgnored == [])
        #expect(byBranch["secrets"]?.notableIgnored == [".env"])
        let later = Date.now.addingTimeInterval(3600)
        #expect(byBranch["merged"]?.isSelectedByDefault(at: later) == true)
        #expect(byBranch["secrets"]?.isSelectedByDefault(at: later) == false)
        // Every worktree here was just written to.
        #expect(byBranch["merged"]?.isSelectedByDefault() == false)
    }

    @Test func trunkWorktreeIsNeverACandidate() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        try await fixture.repository.git(["switch", "-c", "elsewhere"])
        let trunkTree = fixture.root.appendingPathComponent("main-tree")
        try await fixture.repository.git(["worktree", "add", trunkTree.path, "main"])
        #expect(try await WorktreeCleanup.candidates(in: fixture.repository.url).isEmpty)
    }

    @Test func removalDeletesMergedBranchesAndKeepsSquashedOnes() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let merged = try await fixture.worktree("merged", commits: ["merged.txt"])
        let squashed = try await fixture.worktree("squashed", commits: ["squashed.txt"])
        try await fixture.repository.git(["merge", "--no-edit", "merged"])
        try await fixture.repository.git(["merge", "--squash", "squashed"])
        try await fixture.repository.git(["commit", "-m", "feat: squashed"])
        try fixture.write(in: merged, "node_modules/a/index.js", "\n")

        let candidates = try await WorktreeCleanup.candidates(in: fixture.repository.url)
        let outcomes = try await candidates.asyncMap { ($0.tree.branch, try await WorktreeCleanup.remove($0, deletingBranch: true)) }
        #expect(outcomes.first { $0.0 == "merged" }?.1 == .deleted)
        #expect(outcomes.first { $0.0 == "squashed" }?.1 == .keptContentMerged)
        #expect(!FileManager.default.fileExists(atPath: merged.path))
        #expect(!FileManager.default.fileExists(atPath: squashed.path))
        #expect(try await fixture.repository.git(["branch", "--list", "merged"]).isEmpty)
        #expect(try await fixture.repository.git(["branch", "--list", "squashed"]).contains("squashed"))
    }

    @Test func removalRechecksTheWorktreeAfterThePreview() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let edited = try await fixture.worktree("edited", commits: ["edited.txt"])
        let committed = try await fixture.worktree("committed", commits: ["committed.txt"])
        let secrets = try await fixture.worktree("secrets", commits: ["secrets.txt"])
        for branch in ["edited", "committed", "secrets"] { try await fixture.repository.git(["merge", "--no-edit", branch]) }
        let candidates = try await WorktreeCleanup.candidates(in: fixture.repository.url)
        #expect(candidates.count == 3)

        try fixture.write(in: edited, "late.txt", "late\n")
        try fixture.write(in: committed, "late.txt", "late\n")
        try await fixture.git(in: committed, ["add", "late.txt"])
        try await fixture.git(in: committed, ["commit", "-m", "feat: late"])
        try fixture.write(in: secrets, ".env", "TOKEN=1\n")
        for candidate in candidates {
            await #expect(throws: (any Error).self) { try await WorktreeCleanup.remove(candidate, deletingBranch: true) }
            #expect(FileManager.default.fileExists(atPath: candidate.tree.url.path))
        }
        #expect(try await fixture.repository.git(["branch", "--list", "committed"]).contains("committed"))
    }
}

// MARK: - Fixture

private struct Fixture {
    let repository: TestRepository
    let root: URL

    static func create() async throws -> Self {
        let repository = try await TestRepository.create(commits: 1)
        try repository.write(".gitignore", ".env\nnode_modules/\n")
        try await repository.commit("chore: ignore files")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoldGit-status-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Self(repository: repository, root: root.resolvingSymlinksInPath())
    }

    func worktree(_ branch: String, commits files: [String]) async throws -> URL {
        let url = root.appendingPathComponent(branch)
        try await repository.git(["worktree", "add", "-b", branch, url.path, "main"])
        for file in files {
            try write(in: url, file, "\(file)\n")
            try await git(in: url, ["add", file])
            try await git(in: url, ["commit", "-m", "feat: \(file)"])
        }
        return url
    }

    func write(in directory: URL, _ path: String, _ content: String) throws {
        let file = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: file, atomically: true, encoding: .utf8)
    }

    @discardableResult
    func git(in directory: URL, _ arguments: [String]) async throws -> String {
        try await GitRuntime.run(arguments: ["git"] + arguments, currentDirectoryURL: directory).standardOutput
    }

    func remove() {
        repository.remove()
        try? FileManager.default.removeItem(at: root)
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        for element in self { results.append(try await transform(element)) }
        return results
    }
}
