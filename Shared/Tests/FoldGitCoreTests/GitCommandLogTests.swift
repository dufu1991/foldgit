import Foundation
import FoldGitTestSupport
import Testing
@testable import FoldGitCore

struct GitCommandLogTests {
    @Test func repositoryStreamsKeepRunningCommandsWhenCleared() async throws {
        let log = GitCommandLog()
        let first = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let second = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stream = await log.updates(in: first)
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == [])
        let running = await log.begin(arguments: ["git", "fetch"], directory: first, readOnly: false)
        #expect(await iterator.next()?.first?.status == .running)
        let unrelated = await log.begin(arguments: ["git", "status"], directory: second, readOnly: true)
        await log.finish(unrelated, status: .succeeded, duration: 0.1)
        let completed = await log.begin(arguments: ["git", "status"], directory: first, readOnly: true)
        await log.finish(completed, status: .succeeded, duration: 0.1)
        await log.clear(in: first)
        let remaining = await log.records(in: first)
        #expect(remaining.map(\.id) == [running])
        #expect(await log.records(in: second).map(\.id) == [unrelated])
        await log.finish(running, status: .cancelled, duration: 0.2)
        #expect(await log.records(in: first).first?.status == .cancelled)
    }

    @Test func outputLimitsPreserveUnicodeAndSummarizeBlobs() async throws {
        let log = GitCommandLog(outputLimit: 8)
        let directory = FileManager.default.temporaryDirectory
        let id = await log.begin(arguments: ["git", "status"], directory: directory, readOnly: true)
        let output = Data("中文日志内容".utf8)
        await log.capture(id, output: output, error: Data(), exitCode: 0, binaryOutput: false)
        await log.finish(id, status: .succeeded, duration: 0.1)
        let entry = try #require(await log.records(in: directory).first)
        #expect(entry.standardOutput?.text == "中文")
        #expect(entry.standardOutput?.isTruncated == true)
        #expect(entry.standardOutput?.byteCount == output.count)
        let blob = await log.begin(arguments: ["git", "cat-file", "blob", "HEAD:file"], directory: directory, readOnly: true)
        await log.capture(blob, output: Data("private file contents".utf8), error: Data(), exitCode: 0, binaryOutput: true)
        await log.finish(blob, status: .succeeded, duration: 0.1)
        let record = try #require(await log.records(in: directory).first)
        #expect(record.standardOutput?.isBinary == true)
        #expect(record.standardOutput?.text == "")
    }

    @Test func outputSummaryOnlyInspectsTheRetainedPrefix() async throws {
        let log = GitCommandLog(outputLimit: 8)
        let directory = FileManager.default.temporaryDirectory
        // Invalid bytes beyond the retained prefix are counted, not decoded.
        let text = await log.begin(arguments: ["git", "log"], directory: directory, readOnly: true)
        let tail: [UInt8] = Array("abcdefgh".utf8) + [0xFF, 0xFE]
        await log.capture(text, output: tail, error: [UInt8](), exitCode: 0, binaryOutput: false)
        let entry = try #require(await log.records(in: directory).first)
        #expect(entry.standardOutput?.text == "abcdefgh")
        #expect(entry.standardOutput?.isBinary == false)
        #expect(entry.standardOutput?.isTruncated == true)
        #expect(entry.standardOutput?.byteCount == tail.count)
        let binary = await log.begin(arguments: ["git", "show"], directory: directory, readOnly: true)
        await log.capture(binary, output: [0xFF, 0xFE, 0x61], error: [UInt8](), exitCode: 0, binaryOutput: false)
        let record = try #require(await log.records(in: directory).first)
        #expect(record.standardOutput?.isBinary == true)
        #expect(record.standardOutput?.byteCount == 3)
    }

    @Test func credentialsAreRedactedAndArgumentsRemainQuoted() async throws {
        let command = GitLogRedaction.command(["git", "-c", "http.extraheader=Authorization: Bearer header-secret",
            "fetch", "https://user:url-secret@example.com/repo?access_token=query-secret", "--password", "argument-secret", "file name's.txt"])
        for secret in ["header-secret", "url-secret", "query-secret", "argument-secret"] { #expect(!command.contains(secret)) }
        #expect(command.contains("'file name'\\''s.txt'"))
        let log = GitCommandLog()
        let directory = FileManager.default.temporaryDirectory
        let id = await log.begin(arguments: ["git", "fetch"], directory: directory, readOnly: false)
        await log.capture(id, output: Data("https://user:output-secret@example.com".utf8),
                          error: Data("Authorization: Bearer error-secret".utf8), exitCode: 1, binaryOutput: false)
        await log.finish(id, status: .failed, duration: 0.1, failure: "token=failure-secret")
        let entry = try #require(await log.records(in: directory).first)
        #expect(entry.standardOutput?.text.contains("output-secret") == false)
        #expect(entry.standardError?.text.contains("error-secret") == false)
        #expect(entry.failure?.contains("failure-secret") == false)
    }

    @Test func historyEvictsCompletedEntriesAndRespectsTheByteBudget() async throws {
        let log = GitCommandLog(maximumEntries: 2, maximumBytes: 64, outputLimit: 16)
        let directory = FileManager.default.temporaryDirectory
        let running = await log.begin(arguments: ["git", "fetch"], directory: directory, readOnly: false)
        let old = await log.begin(arguments: ["git", "status"], directory: directory, readOnly: true)
        await log.finish(old, status: .succeeded, duration: 0.1)
        let latest = await log.begin(arguments: ["git", "diff"], directory: directory, readOnly: true)
        #expect(await log.records(in: directory).map(\.id) == [latest, running])
        await log.capture(latest, output: Data(repeating: 97, count: 64), error: Data(repeating: 98, count: 64), exitCode: 0, binaryOutput: false)
        await log.finish(latest, status: .succeeded, duration: 0.1, failure: String(repeating: "c", count: 64))
        let entries = await log.records(in: directory)
        #expect(entries.count <= 2)
        #expect(entries.contains { $0.id == running })
        #expect(!entries.contains { $0.id == old })
    }

    @Test func runtimeRecordsActualArgumentsOutputsAndFailureIdentity() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        await GitCommandLog.shared.clear(in: repository.url)
        try await GitRuntime.read(at: repository.url, readOnly: true) { session in
            _ = try await session.run(GitStatus(directory: repository.url))
        }
        let success = try #require(await GitCommandLog.shared.records(in: repository.url).first)
        #expect(success.command.hasPrefix("git -c core.quotepath=false -c color.ui=false "))
        #expect(success.status == .succeeded)
        #expect(success.exitCode == 0)
        #expect(success.duration != nil)
        #expect(success.isReadOnly)
        do {
            _ = try await repository.git(["rev-parse", "--verify", "refs/heads/missing-branch"])
            Issue.record("The invalid ref unexpectedly resolved")
        } catch let error as GitExecutionError {
            let failure = try #require(await GitCommandLog.shared.records(in: repository.url).first)
            #expect(failure.status == .failed)
            #expect(failure.exitCode != 0)
            #expect(failure.standardError?.text.isEmpty == false)
            #expect(error.commandLogID == failure.id)
            #expect(error.directory == repository.url)
        }
        _ = try await GitRuntime.runData(arguments: ["git", "cat-file", "blob", "HEAD:example.swift"], currentDirectoryURL: repository.url)
        let binary = try #require(await GitCommandLog.shared.records(in: repository.url).first)
        #expect(binary.standardOutput?.isBinary == true)
        #expect(binary.standardOutput?.text.isEmpty == true)
    }
}
