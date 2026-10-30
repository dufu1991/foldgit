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

    @Test func commandLogsFinishOnTimeoutCancellationAndLaunchFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FoldGit-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("git")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        await #expect(throws: GitExecutionError.self) {
            try await GitRuntime.run(arguments: [executable.path], currentDirectoryURL: directory, timeout: .milliseconds(100))
        }
        #expect(await GitCommandLog.shared.records(in: directory).first?.status == .timedOut)
        let task = Task { try await GitRuntime.run(arguments: [executable.path], currentDirectoryURL: directory) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while await GitCommandLog.shared.records(in: directory).first?.status != .running, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await GitCommandLog.shared.records(in: directory).first?.status == .running)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await GitCommandLog.shared.records(in: directory).first?.status == .cancelled)

        try FileManager.default.removeItem(at: executable)
        await #expect(throws: GitExecutionError.self) {
            try await GitRuntime.run(arguments: [executable.path], currentDirectoryURL: directory)
        }
        let failed = try #require(await GitCommandLog.shared.records(in: directory).first)
        #expect(failed.status == .failed)
        #expect(failed.exitCode == nil)
        #expect(failed.failure?.isEmpty == false)
    }
}
