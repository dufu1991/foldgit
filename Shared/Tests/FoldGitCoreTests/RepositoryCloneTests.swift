import FoldGitCore
import FoldGitTestSupport
import Foundation
import Testing

private actor CloneLines {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

struct RepositoryCloneTests {
    @Test func folderNamesSupportHTTPSAndSSHAddresses() {
        for address in ["https://example.com/team/repo.git", "git@example.com:team/repo.git", "ssh://git@example.com/team/repo.git", "https://example.com/team/repo.git/"] {
            #expect(RepositoryCloneRequest.suggestedName(for: address) == "repo")
        }
        #expect(RepositoryCloneRequest.suggestedName(for: "https://example.com/team/%E9%A1%B9%E7%9B%AE.git") == "项目")
    }

    @Test func cloneReportsProgressPreservesOriginAndAddsToRepositoryDiscovery() async throws {
        let source = try await TestRepository.create()
        defer { source.remove() }
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("FoldGit-clone-test-\(UUID())")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let request = RepositoryCloneRequest(parent: parent, remote: source.url.absoluteString, directoryName: "克隆 项目")
        let lines = CloneLines()
        let url = try await RepositoryClone.run(request) { await lines.append($0) }
        #expect(url == request.destination)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("example.swift").path))
        let origin = try await GitRuntime.run(arguments: ["git", "remote", "get-url", "origin"], currentDirectoryURL: url)
        #expect(origin.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == source.url.absoluteString)
        #expect(!(await lines.values).isEmpty)
        let discovered = try await RepositoryDiscovery().scanGroup(parent)
        #expect(discovered.repositories.map(\.identity) == [WorkspaceEntry(url: url).identity])
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["克隆 项目"])
    }

    @Test func validationAndFailureLeaveExistingDataUntouchedAndAllowRetry() async throws {
        let source = try await TestRepository.create()
        defer { source.remove() }
        let parent = source.url.appendingPathComponent("clones")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let existing = parent.appendingPathComponent("existing")
        try "保留内容".write(to: existing, atomically: true, encoding: .utf8)
        for name in ["existing", "..", "../escape", "nested/repo", ""] {
            let request = RepositoryCloneRequest(parent: parent, remote: source.url.absoluteString, directoryName: name)
            #expect(throws: (any Error).self) { try request.validate() }
        }
        for remote in ["--upload-pack=bad", "ext::bad", "not an address", "https://example.com/repo\nargument"] {
            let request = RepositoryCloneRequest(parent: parent, remote: remote, directoryName: "repo")
            #expect(throws: (any Error).self) { try request.validate() }
        }
        let bad = RepositoryCloneRequest(parent: parent, remote: source.url.appendingPathComponent("missing.git").path, directoryName: "retry")
        await #expect(throws: (any Error).self) { try await RepositoryClone.run(bad) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["existing"])
        #expect(try String(contentsOf: existing, encoding: .utf8) == "保留内容")
        let retry = RepositoryCloneRequest(parent: parent, remote: source.url.path, directoryName: "retry")
        _ = try await RepositoryClone.run(retry)
        #expect(FileManager.default.fileExists(atPath: retry.destination.appendingPathComponent(".git").path))
    }

    @Test func cancellationStopsProcessAndRemovesOnlyItsStagingDirectory() async throws {
        let source = try await TestRepository.create()
        defer { source.remove() }
        let parent = source.url.appendingPathComponent("clones")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let request = RepositoryCloneRequest(parent: parent, remote: source.url.path, directoryName: "canceled")
        let clone = Task { try await RepositoryClone.run(request) { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        } }
        await #expect(throws: (any Error).self) { try await clone.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }
}

struct RepositoryActivityTests {
    @Test func nestedFileChangesCountAndIgnoredFilesDoNotAffectModificationDate() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        try repository.write(".gitignore", "ignored/\n")
        try repository.write("nested/file.swift", "let value = 1\n")
        try await repository.commit("feat: nested file")
        let old = Date(timeIntervalSince1970: 100)
        let changed = Date(timeIntervalSince1970: 200)
        for path in ["example.swift", ".gitignore", "nested/file.swift"] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: repository.url.appendingPathComponent(path).path)
        }
        try FileManager.default.setAttributes([.modificationDate: changed], ofItemAtPath: repository.url.appendingPathComponent("nested/file.swift").path)
        try repository.write("ignored/cache", "newer ignored file")
        let activity = RepositoryActivity()
        #expect(try await activity.modificationDate(at: repository.url) == changed)
        try repository.write("untracked.swift", "let value = 2\n")
        let latest = try await RepositoryActivity().modificationDate(at: repository.url)
        #expect(try #require(latest) > changed)
        // A fresh scan is not started every time the search field updates.
        #expect(try await activity.modificationDate(at: repository.url) == changed)
    }
}
