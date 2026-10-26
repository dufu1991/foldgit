import Foundation
import FoldGitTestSupport
import Testing
@testable import FoldGitCore

struct GitFileContentTests {
    @Test func preservesBinaryBytesAcrossCommitIndexAndWorkingTree() async throws {
        let repository = try await TestRepository.create(commits: 0)
        defer { repository.remove() }
        let path = "图片 asset.png"
        let url = repository.url.appendingPathComponent(path)
        let committed = Data([0, 255, 137, 80, 78, 71, 13, 10])
        let staged = Data([0, 254, 1, 2, 3])
        let working = Data([0, 253, 4, 5, 6, 7])
        try committed.write(to: url)
        try await repository.commit("Add image")
        try staged.write(to: url)
        try await repository.git(["add", "--", path])
        try working.write(to: url)
        #expect(try await GitFileContent.read(at: repository.url, path: path, version: .revision("HEAD")) == committed)
        #expect(try await GitFileContent.read(at: repository.url, path: path, version: .index) == staged)
        #expect(try await GitFileContent.read(at: repository.url, path: path, version: .workingTree) == working)
        #expect(try await GitFileContent.read(at: repository.url, path: path, version: .absent) == nil)
        let object = try await repository.git(["rev-parse", "HEAD:\(path)"])
        #expect(try await GitFileContent.read(at: repository.url, path: "renamed.png", version: .blob(object)) == committed)
    }

    @Test func missingContentIsAnErrorRatherThanAnEmptyImage() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        await #expect(throws: (any Error).self) {
            try await GitFileContent.read(at: repository.url, path: "missing.png", version: .revision("HEAD"))
        }
        await #expect(throws: (any Error).self) {
            try await GitFileContent.read(at: repository.url, path: "missing.png", version: .workingTree)
        }
    }

    @Test func binaryReadsRespectCancellation() async throws {
        let task = Task {
            try await GitRuntime.runData(arguments: ["/bin/sleep", "30"], currentDirectoryURL: nil)
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
