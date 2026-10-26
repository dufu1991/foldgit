import Foundation
import FoldGitCore

public struct TestRepository: Sendable {
    public let url: URL

    public static func create(commits: Int = 1) async throws -> Self {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FoldGit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let repository = Self(url: url)
        try await repository.git(["init", "--initial-branch=main"])
        try await repository.git(["config", "user.name", "FoldGit Tests"])
        try await repository.git(["config", "user.email", "tests@example.com"])
        try await repository.git(["config", "commit.gpgsign", "false"])
        try await repository.git(["config", "tag.gpgsign", "false"])
        try await repository.git(["config", "core.autocrlf", "false"])
        for index in 0..<commits {
            try repository.write("example.swift", "let value = \(index)\n")
            try await repository.commit("feat: commit \(index)")
        }
        return repository
    }

    @discardableResult
    public func git(_ arguments: [String]) async throws -> String {
        try await GitRuntime.run(arguments: ["git"] + arguments, currentDirectoryURL: url).standardOutput.trimmingCharacters(in: .newlines)
    }

    public func write(_ path: String, _ content: String) throws {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: file, atomically: true, encoding: .utf8)
    }

    public func commit(_ message: String) async throws {
        try await git(["add", "--all"])
        try await git(["commit", "--allow-empty", "-m", message])
    }

    public func remove() { try? FileManager.default.removeItem(at: url) }
}
