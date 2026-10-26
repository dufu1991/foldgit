import FoldGitCore
import Foundation
import Testing
@testable import FoldGit

struct GitRuntimeTests {
    @Test func drainsBothOutputStreamsWithoutBlocking() async throws {
        let output = try await GitRuntime.run(arguments: ["/usr/bin/python3", "-c",
            "import sys;sys.stdout.write('a'*1048576);sys.stdout.flush();sys.stderr.write('b'*1048576)"],
            currentDirectoryURL: nil)
        #expect(output.standardOutput.utf8.count == 1_048_576)
        #expect(output.standardError.utf8.count == 1_048_576)
    }

    @Test func inputIsClosedAndUnicodeIsPreserved() async throws {
        let output = try await GitRuntime.run(arguments: ["/bin/cat"], currentDirectoryURL: nil, inputs: ["中文 UTF-8"])
        #expect(output.standardOutput == "中文 UTF-8\n")
        let empty = try await GitRuntime.run(arguments: ["/bin/cat"], currentDirectoryURL: nil)
        #expect(empty.standardOutput.isEmpty)
    }

    @Test func timeoutTerminatesAChildProcess() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: (any Error).self) {
            try await GitRuntime.run(arguments: ["/bin/sleep", "30"], currentDirectoryURL: nil, timeout: .milliseconds(100))
        }
        #expect(start.duration(to: clock.now) < .seconds(3))
    }

    @Test func taskCancellationTerminatesAChildProcess() async throws {
        let task = Task { try await GitRuntime.run(arguments: ["/bin/sleep", "30"], currentDirectoryURL: nil) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
