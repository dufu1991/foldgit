import FoldGitCore
import Foundation
import XCTest
@testable import FoldGit

final class GitRepositoryDiscoveryTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("repository-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func git(_ arguments: [String], in directory: URL) async throws {
        _ = try await GitRuntime.run(arguments: ["git"] + arguments, currentDirectoryURL: directory)
    }

    func testRepositoryRootWinsOverNestedRepositories() async throws {
        let root = try temporaryDirectory()
        try await git(["init", "."], in: root)
        try await git(["init", "nested"], in: root)
        let result = try await RepositoryDiscovery().inspect(root)
        XCTAssertTrue(result.isRepository)
        XCTAssertNil(result.children)
        XCTAssertEqual(result.identity, root.resolvingSymlinksInPath())
    }

    func testGroupContainsOnlyImmediateIndependentRepositories() async throws {
        let root = try temporaryDirectory()
        try await git(["init", "web"], in: root)
        try await git(["init", "api"], in: root)
        try await git(["init", "ordinary/deep"], in: root)
        try await git(["init", "--bare", "remote.git"], in: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("invalid/.git"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"),
                                                 withDestinationURL: root.appendingPathComponent("api"))
        let result = try await RepositoryDiscovery().inspect(root)
        XCTAssertFalse(result.isRepository)
        XCTAssertEqual(result.children?.map(\.displayName), ["api", "web"])
        XCTAssertEqual(result.repositories.count, 2)
    }

    func testOrdinarySubdirectoryDoesNotInheritItsParentsRepository() async throws {
        let root = try temporaryDirectory()
        try await git(["init", "."], in: root)
        let sources = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        do {
            _ = try await RepositoryDiscovery().inspect(sources)
            XCTFail("An ordinary working-tree subdirectory is not a separate repository")
        } catch {
            XCTAssertTrue(error is RepositoryDiscovery.DiscoveryError)
        }
    }

    func testWorktreeWithGitFileIsRecognized() async throws {
        let root = try temporaryDirectory()
        try await git(["init", "main"], in: root)
        let main = root.appendingPathComponent("main")
        try await git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "Initial"], in: main)
        let worktree = root.appendingPathComponent("worktree")
        try await git(["worktree", "add", "-b", "feature", worktree.path], in: main)
        let result = try await RepositoryDiscovery().inspect(worktree)
        XCTAssertTrue(result.isRepository)
        let group = try await RepositoryDiscovery().inspect(root)
        XCTAssertEqual(group.children?.map(\.displayName), ["main", "worktree"])
    }

    func testRefreshDiscoversAddedAndRemovedRepositories() async throws {
        let root = try temporaryDirectory()
        let discovery = RepositoryDiscovery()
        try await git(["init", "first"], in: root)
        let original = try await discovery.inspect(root)
        XCTAssertEqual(original.children?.map(\.displayName), ["first"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("first"))
        try await git(["init", "second"], in: root)
        let refreshed = try await discovery.scanGroup(root)
        XCTAssertEqual(refreshed.children?.map(\.displayName), ["second"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("second"))
        let empty = try await discovery.scanGroup(root)
        XCTAssertFalse(empty.isRepository)
        XCTAssertEqual(empty.children, [])
    }

    func testLegacyFoldersDecodeAsRepositoriesAndGroupOrderSurvives() throws {
        let root = try temporaryDirectory()
        let legacy = try JSONSerialization.data(withJSONObject: [["url": root.absoluteString]])
        let decoded = try JSONDecoder().decode([WorkspaceEntry].self, from: legacy)
        XCTAssertEqual(decoded, [WorkspaceEntry(url: root)])
        XCTAssertEqual(decoded[0].symbol, "arrow.triangle.branch")
        let group = WorkspaceEntry(url: root, children: [WorkspaceEntry(url: root.appendingPathComponent("web")),
                                                WorkspaceEntry(url: root.appendingPathComponent("api"))])
        let folders = [group, WorkspaceEntry(url: root.appendingPathComponent("standalone"))]
        let restored = try JSONDecoder().decode([WorkspaceEntry].self, from: JSONEncoder().encode(folders))
        XCTAssertEqual(restored, folders)
        XCTAssertEqual(restored.flatMap(\.repositories).map(\.displayName), ["web", "api", "standalone"])
        XCTAssertEqual(group.symbol, "folder")
    }

    func testInfrequentRepositoryStaysInItsGroupAndCanBeRestored() throws {
        let root = try temporaryDirectory()
        let api = WorkspaceEntry(url: root.appendingPathComponent("api"))
        let web = WorkspaceEntry(url: root.appendingPathComponent("web"))
        var group = WorkspaceEntry(url: root, children: [api, web])
        group.setInfrequent(true, repository: web)
        group.setInfrequent(true, repository: web)
        XCTAssertEqual(group.url, root)
        XCTAssertEqual(group.children, [api, web])
        XCTAssertEqual(group.frequentRepositories, [api])
        XCTAssertEqual(group.infrequentRepositories, [web])
        XCTAssertEqual(group.repositories, [api, web])
        XCTAssertEqual(group.infrequentRepositoryURLs, [web.identity])
        let restored = try JSONDecoder().decode(WorkspaceEntry.self, from: JSONEncoder().encode(group))
        XCTAssertEqual(restored, group)
        XCTAssertEqual(restored.infrequentRepositories, [web])
        group.setInfrequent(false, repository: web)
        XCTAssertEqual(group.frequentRepositories, [api, web])
        XCTAssertTrue(group.infrequentRepositories.isEmpty)
        XCTAssertNil(group.infrequentRepositoryURLs)
        let original = group
        group.setInfrequent(true, repository: WorkspaceEntry(url: root.appendingPathComponent("outside")))
        XCTAssertEqual(group, original)
    }

    func testRefreshAndReaddingGroupPreserveInfrequentChoices() throws {
        let root = try temporaryDirectory()
        let api = WorkspaceEntry(url: root.appendingPathComponent("api"))
        let web = WorkspaceEntry(url: root.appendingPathComponent("web"))
        let new = WorkspaceEntry(url: root.appendingPathComponent("worker"))
        var group = WorkspaceEntry(url: root, children: [api, web])
        group.setInfrequent(true, repository: web)
        let discovered = WorkspaceEntry(url: root, children: [api, web, new])
        let refreshed = group.mergingDiscovery(discovered)
        XCTAssertEqual(refreshed.frequentRepositories, [api, new])
        XCTAssertEqual(refreshed.infrequentRepositories, [web])
        let temporarilyMissing = refreshed.mergingDiscovery(WorkspaceEntry(url: root, children: [api, new]))
        XCTAssertTrue(temporarilyMissing.infrequentRepositories.isEmpty)
        XCTAssertEqual(temporarilyMissing.mergingDiscovery(discovered).infrequentRepositories, [web])
    }
}
